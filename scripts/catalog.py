"""Keep a shelf inventory consistent by driving it from a declared taxonomy.

`data/catalog.toml` declares the categories, custom fields, tags, locations and asset models the
inventory may use. `sync` makes the database match it, `check` reports drift, and `add` / `update`
write assets from batch files that are validated against it first, so nothing can be filed under
an undeclared category, tag or field.

Writes mirror what shelf 2.2.0's own services do (an asset gets its QR code, location row, field
values and a "created" activity note; a new custom field gets its asset-index column), each run in
one transaction. Re-verify these against shelf's services before pinning a newer shelf version.

Run through the CLI: `.\\docker-compose.ps1 catalog <command> [file]`.
"""

import argparse
import datetime
import io
import json
import math
import os
import secrets
import string
import subprocess
import sys
import tomllib
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "data")
CATALOG_PATH = os.path.join(DATA_DIR, "catalog.toml")
CONFIG_PATH = os.path.join(ROOT, "config.env")
FIELD_TYPES = {"TEXT", "NUMBER", "AMOUNT", "OPTION", "BOOLEAN", "DATE", "MULTILINE_TEXT"}
ASSET_KEYS = {"id", "title", "description", "category", "model", "location", "tags", "fields", "value", "image"}
THUMBNAIL_SIZE = 108
PRODUCT_IMAGE_SIZE = 1200
PRODUCT_IMAGE_MARGIN = 0.06
CUTOUT_IMAGE = "danielgatis/rembg"
CUTOUT_MODEL = "birefnet-general"
LABELS_PATH = os.path.join(DATA_DIR, "labels", "labels.pdf")
PAGE_SIZE_MM = (210, 297)
# From a 100 dpi scan of the CD label sheet, corrected for the 2.5 mm the scanner cut off the left
# edge and 1.9 mm off the top: centred across the page and symmetric top to bottom.
RING_CENTRES_MM = ((105, 74), (105, 223))
RING_OUTER_RADIUS_MM = 58.5
RING_HOLE_RADIUS_MM = 20.5
RING_SAFETY_MM = 2.5
LABEL_SIZE_MM = (13, 15)
LABEL_GAP_MM = 1.0
LABEL_PADDING_MM = 0.6
LABEL_TEXT_SIZE_MM = 2.6
QR_QUIET_MODULES = 2
HELVETICA_BOLD_WIDTHS = {"S": 667, "A": 722, "M": 833, "-": 333, **{digit: 556 for digit in "0123456789"}}
RENAMEABLE = ("categories", "tags", "locations", "models")
SINGULAR = {"categories": "category", "fields": "field", "tags": "tag", "locations": "location", "models": "model"}


class CatalogError(Exception):
    pass


def run_sql(sql, want_rows=False):
    """Runs SQL in one transaction inside the db container; returns rows as JSON objects."""
    command = ["docker", "exec", "-i", "shelf-db", "psql", "-U", "postgres", "-d", "postgres",
               "-v", "ON_ERROR_STOP=1", "-X", "-q", "-t", "-A", "-1"]
    result = subprocess.run(command, input=sql.encode("utf-8"), capture_output=True)
    if result.returncode != 0:
        raise CatalogError(result.stderr.decode("utf-8", "replace").strip())
    output = result.stdout.decode("utf-8").strip()
    if not want_rows:
        return None
    return json.loads(output) if output else []


def query(select_sql):
    return run_sql(f"select coalesce(json_agg(q), '[]'::json) from ({select_sql}) q;", want_rows=True)


def literal(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def text_array(values):
    return "ARRAY[" + ", ".join(literal(v) for v in values) + "]::text[]" if values else "ARRAY[]::text[]"


def new_id(length=25):
    alphabet = string.ascii_lowercase + string.digits
    return "c" + "".join(secrets.choice(alphabet) for _ in range(length - 1))


def new_qr_id():
    alphabet = string.ascii_lowercase + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(10))


def read_config():
    values = {}
    with open(CONFIG_PATH, encoding="utf-8") as handle:
        for line in handle:
            name, separator, value = line.strip().partition("=")
            if separator and not name.startswith("#"):
                values[name.strip()] = value.strip().strip('"')
    return values


def load_toml(path):
    try:
        with open(path, "rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError:
        raise CatalogError(f"{path} not found")
    except tomllib.TOMLDecodeError as error:
        raise CatalogError(f"{path}: {error}")


def load_catalog():
    catalog = load_toml(CATALOG_PATH)
    taxonomy = {kind: {entry["name"].lower(): entry for entry in catalog.get(kind, [])}
                for kind in ("categories", "fields", "tags", "locations", "models")}
    for field in taxonomy["fields"].values():
        if field.get("type", "TEXT") not in FIELD_TYPES:
            raise CatalogError(f"field '{field['name']}': unknown type {field.get('type')}")
        if field.get("type") == "OPTION" and not field.get("options"):
            raise CatalogError(f"field '{field['name']}': OPTION fields need options")
        for category in field.get("categories", []):
            require(taxonomy, "categories", category, f"field '{field['name']}'")
    for location in taxonomy["locations"].values():
        if location.get("parent"):
            require(taxonomy, "locations", location["parent"], f"location '{location['name']}'")
    for model in taxonomy["models"].values():
        require(taxonomy, "categories", model["category"], f"model '{model['name']}'")
        if model.get("image") and not os.path.isfile(model_image_path(model)):
            raise CatalogError(f"model '{model['name']}': image data/{model['image']} not found")
    return taxonomy


def model_image_path(model):
    return os.path.join(DATA_DIR, model["image"]) if model.get("image") else None


def require(taxonomy, kind, name, context):
    entry = taxonomy[kind].get(str(name).lower())
    if entry is None:
        raise CatalogError(f"{context}: '{name}' is not declared under [[{kind}]] in data/catalog.toml")
    return entry


def workspace():
    rows = query('select o.id as org, u.id as "user", trim(coalesce(u."firstName", \'\') || \' \' || '
                 'coalesce(u."lastName", \'\')) as "userName" from "Organization" o join "User" u on u.id = o."userId"')
    if len(rows) != 1:
        raise CatalogError(f"expected exactly one organization, found {len(rows)}")
    return rows[0]


def db_state():
    return {
        "categories": {r["name"].lower(): r for r in query(
            'select c.id, c.name, c.description, c.color, (select count(*) from "Asset" a where a."categoryId" = c.id) as uses from "Category" c')},
        "fields": {r["name"].lower(): r for r in query(
            'select f.id, f.name, f.type, f.options, f."helpText", f.required, f.active, '
            '(select count(*) from "AssetCustomFieldValue" v where v."customFieldId" = f.id) as uses, '
            'coalesce((select json_agg(c.name) from "_CategoryToCustomField" x join "Category" c on c.id = x."A" where x."B" = f.id), \'[]\') as categories '
            'from "CustomField" f where f."deletedAt" is null')},
        "tags": {r["name"].lower(): r for r in query(
            'select t.id, t.name, t.description, (select count(*) from "_AssetToTag" x where x."B" = t.id) as uses from "Tag" t')},
        "locations": {r["name"].lower(): r for r in query(
            'select l.id, l.name, l.description, p.name as parent, (select count(*) from "AssetLocation" x where x."locationId" = l.id) as uses '
            'from "Location" l left join "Location" p on p.id = l."parentId"')},
        "models": {r["name"].lower(): r for r in query(
            'select m.id, m.name, m.description, c.name as category, (select count(*) from "Asset" a where a."assetModelId" = m.id) as uses '
            'from "AssetModel" m left join "Category" c on c.id = m."defaultCategoryId"')},
    }


def field_value_json(field, raw):
    """Builds the JSON shelf stores for one value; mirrors buildCustomFieldValue in shelf."""
    kind = field.get("type", "TEXT")
    name = field["name"]
    if kind == "BOOLEAN":
        if not isinstance(raw, bool):
            raise CatalogError(f"field '{name}' expects true or false, got {raw!r}")
        return {"raw": raw, "valueBoolean": raw}
    if kind in ("NUMBER", "AMOUNT"):
        if isinstance(raw, bool) or not isinstance(raw, (int, float)):
            raise CatalogError(f"field '{name}' expects a number, got {raw!r}")
        text = str(int(raw)) if float(raw).is_integer() else repr(float(raw))
        return {"raw": raw, "valueText": text}
    if kind == "OPTION":
        if raw not in field["options"]:
            raise CatalogError(f"field '{name}' must be one of {field['options']}, got {raw!r}")
        return {"raw": raw, "valueOption": raw}
    if kind == "DATE":
        try:
            day = datetime.date.fromisoformat(str(raw))
        except ValueError:
            raise CatalogError(f"field '{name}' expects YYYY-MM-DD, got {raw!r}")
        return {"raw": day.isoformat(), "valueDate": day.isoformat() + "T00:00:00.000Z"}
    if kind == "MULTILINE_TEXT":
        return {"raw": str(raw), "valueMultiLineText": str(raw)}
    return {"raw": str(raw), "valueText": str(raw)}


def index_column_sql(field_name, field_type, active, old_name=None):
    """Mirrors syncCustomFieldColumn: shelf's asset list only shows fields it has a column for."""
    old = literal("cf_" + (old_name or field_name))
    new = literal("cf_" + field_name)
    if not active:
        return (f'update "AssetIndexSettings" set columns = (select coalesce(jsonb_agg(c), \'[]\') from jsonb_array_elements(columns::jsonb) c '
                f'where c->>\'name\' <> {old}), "updatedAt" = now();\n')
    return (f'update "AssetIndexSettings" s set columns = case when exists (select 1 from jsonb_array_elements(s.columns::jsonb) c where c->>\'name\' = {old}) '
            f'then (select jsonb_agg(case when c->>\'name\' = {old} then c || jsonb_build_object(\'name\', {new}, \'cfType\', {literal(field_type)}) else c end) '
            f'from jsonb_array_elements(s.columns::jsonb) c) '
            f'else s.columns::jsonb || jsonb_build_array(jsonb_build_object(\'name\', {new}, \'visible\', true, '
            f'\'position\', (select coalesce(max((c->>\'position\')::int), 0) + 1 from jsonb_array_elements(s.columns::jsonb) c), \'cfType\', {literal(field_type)})) end, '
            f'"updatedAt" = now();\n')


def sync(taxonomy, ws, prune):
    state = db_state()
    report = [f"~ {SINGULAR[kind]} {old} renamed to {new}" for kind, old, new in adopt_declared_renames(taxonomy, state)]
    renames = likely_renames(taxonomy, state)
    if renames:
        kind, declared, actual = renames[0]
        raise CatalogError(f"{SINGULAR[kind]} '{declared}' looks renamed to '{actual}' in shelf; syncing now would create a "
                           f"duplicate. Rename it in data/catalog.toml (or back in shelf) first")
    sql = []
    org, user = literal(ws["org"]), literal(ws["user"])

    for key, category in taxonomy["categories"].items():
        existing = state["categories"].get(key)
        values = (literal(category["name"]), literal(category.get("description")), literal(category.get("color", "#6b7280")))
        if existing:
            sql.append(f'update "Category" set name = {values[0]}, description = {values[1]}, color = {values[2]}, "updatedAt" = now() '
                       f'where id = {literal(existing["id"])};\n')
        else:
            category_id = new_id()
            state["categories"][key] = {"id": category_id, "name": category["name"], "uses": 0}
            sql.append(f'insert into "Category" (id, name, description, color, "userId", "organizationId", "updatedAt") '
                       f'values ({literal(category_id)}, {values[0]}, {values[1]}, {values[2]}, {user}, {org}, now());\n')
            report.append(f"+ category {category['name']}")

    for key, location in parents_first(taxonomy["locations"]):
        existing = state["locations"].get(key)
        if existing:
            location_id = existing["id"]
            sql.append(f'update "Location" set name = {literal(location["name"])}, description = {literal(location.get("description"))}, '
                       f'"updatedAt" = now() where id = {literal(location_id)};\n')
        else:
            location_id = new_id()
            state["locations"][key] = {"id": location_id, "name": location["name"], "uses": 0}
            sql.append(f'insert into "Location" (id, name, description, "userId", "organizationId", "updatedAt") '
                       f'values ({literal(location_id)}, {literal(location["name"])}, {literal(location.get("description"))}, {user}, {org}, now());\n')
            report.append(f"+ location {location['name']}")
        parent = location.get("parent")
        parent_sql = literal(state["locations"][parent.lower()]["id"]) if parent else "null"
        sql.append(f'update "Location" set "parentId" = {parent_sql} where id = {literal(location_id)};\n')

    for key, tag in taxonomy["tags"].items():
        existing = state["tags"].get(key)
        if existing:
            sql.append(f'update "Tag" set name = {literal(tag["name"])}, description = {literal(tag.get("description"))}, "updatedAt" = now() '
                       f'where id = {literal(existing["id"])};\n')
        else:
            sql.append(f'insert into "Tag" (id, name, description, "userId", "organizationId", "updatedAt") '
                       f'values ({literal(new_id())}, {literal(tag["name"])}, {literal(tag.get("description"))}, {user}, {org}, now());\n')
            report.append(f"+ tag {tag['name']}")

    for key, field in taxonomy["fields"].items():
        existing = state["fields"].get(key)
        field_type = field.get("type", "TEXT")
        if existing:
            if existing["type"] != field_type and existing["uses"]:
                raise CatalogError(f"field '{field['name']}' is {existing['type']} with {existing['uses']} values; changing it to {field_type} "
                                   f"would corrupt them")
            field_id = existing["id"]
            sql.append(f'update "CustomField" set name = {literal(field["name"])}, type = {literal(field_type)}::"CustomFieldType", '
                       f'options = {text_array(field.get("options", []))}, "helpText" = {literal(field.get("help"))}, '
                       f'required = {literal(field.get("required", False))}, active = true, "updatedAt" = now() where id = {literal(field_id)};\n')
        else:
            field_id = new_id()
            sql.append(f'insert into "CustomField" (id, name, "helpText", required, type, options, "organizationId", "userId", "updatedAt") '
                       f'values ({literal(field_id)}, {literal(field["name"])}, {literal(field.get("help"))}, {literal(field.get("required", False))}, '
                       f'{literal(field_type)}::"CustomFieldType", {text_array(field.get("options", []))}, {org}, {user}, now());\n')
            report.append(f"+ field {field['name']} ({field_type})")
        sql.append(index_column_sql(field["name"], field_type, True, existing["name"] if existing else None))
        sql.append(f'delete from "_CategoryToCustomField" where "B" = {literal(field_id)};\n')
        for category in field.get("categories", []):
            sql.append(f'insert into "_CategoryToCustomField" ("A", "B") values ({literal(state["categories"][category.lower()]["id"])}, {literal(field_id)});\n')

    for key, model in taxonomy["models"].items():
        existing = state["models"].get(key)
        category_id = literal(state["categories"][model["category"].lower()]["id"])
        if existing:
            sql.append(f'update "AssetModel" set name = {literal(model["name"])}, description = {literal(model.get("description"))}, '
                       f'"defaultCategoryId" = {category_id}, "defaultValuation" = {literal(model.get("value"))}, "updatedAt" = now() '
                       f'where id = {literal(existing["id"])};\n')
        else:
            sql.append(f'insert into "AssetModel" (id, name, description, "defaultCategoryId", "defaultValuation", "organizationId", "userId", "updatedAt") '
                       f'values ({literal(new_id())}, {literal(model["name"])}, {literal(model.get("description"))}, {category_id}, '
                       f'{literal(model.get("value"))}, {org}, {user}, now());\n')
            report.append(f"+ model {model['name']}")

    if prune:
        for kind, table in (("categories", "Category"), ("tags", "Tag"), ("models", "AssetModel"), ("locations", "Location")):
            for key, row in state[kind].items():
                if key in taxonomy[kind] or "id" not in row or row.get("uses") is None:
                    continue
                if row["uses"]:
                    report.append(f"! kept undeclared {SINGULAR[kind]} {row['name']}: {row['uses']} assets still use it")
                    continue
                sql.append(f'delete from "{table}" where id = {literal(row["id"])};\n')
                report.append(f"- {SINGULAR[kind]} {row['name']}")
        for key, row in state["fields"].items():
            if key in taxonomy["fields"]:
                continue
            if row["uses"]:
                report.append(f"! kept undeclared field {row['name']}: {row['uses']} values")
                continue
            sql.append(f'update "CustomField" set active = false, "deletedAt" = now(), "updatedAt" = now() where id = {literal(row["id"])};\n')
            sql.append(index_column_sql(row["name"], row["type"], False))
            report.append(f"- field {row['name']}")

    run_sql("".join(sql))
    return report or ["taxonomy already in sync"]


def parents_first(locations):
    ordered, placed = [], set()
    while len(ordered) < len(locations):
        ready = [(k, v) for k, v in locations.items()
                 if k not in placed and (not v.get("parent") or v["parent"].lower() in placed)]
        if not ready:
            raise CatalogError("locations have a parent cycle")
        ordered += ready
        placed.update(k for k, _ in ready)
    return ordered


def adopt_declared_renames(taxonomy, state):
    """Re-keys a row under the name that declares `renamed_from` it, so sync updates that row instead of adding a new one.

    @implNote Fields are left out: renaming one also has to move its asset-index column.
    """
    adopted = []
    for kind in RENAMEABLE:
        for key, entry in taxonomy[kind].items():
            old = str(entry.get("renamed_from", "")).lower()
            if old and key not in state[kind] and old in state[kind]:
                state[kind][key] = state[kind].pop(old)
                adopted.append((kind, entry["renamed_from"], entry["name"]))
    return adopted


def likely_renames(taxonomy, state):
    """A single declared-but-missing entry next to a single undeclared one is a rename made in the UI."""
    renames = []
    for kind in ("categories", "fields", "tags", "locations", "models"):
        missing = [entry["name"] for key, entry in taxonomy[kind].items() if key not in state[kind]]
        undeclared = [row["name"] for key, row in state[kind].items() if key not in taxonomy[kind]]
        if len(missing) == 1 and len(undeclared) == 1:
            renames.append((kind, missing[0], undeclared[0]))
    return renames


def check(taxonomy):
    state, problems = db_state(), []
    for kind, old, new in adopt_declared_renames(taxonomy, state):
        problems.append(f"{SINGULAR[kind]} '{old}' is declared renamed to '{new}'; run sync")
    for kind, declared, actual in likely_renames(taxonomy, state):
        problems.append(f"{SINGULAR[kind]} '{declared}' looks renamed to '{actual}' in shelf; rename it in data/catalog.toml")
    for kind in ("categories", "fields", "tags", "locations", "models"):
        for key, row in state[kind].items():
            if key not in taxonomy[kind]:
                problems.append(f"undeclared {SINGULAR[kind]} in shelf: {row['name']} ({row.get('uses', 0)} uses)")
        for key, entry in taxonomy[kind].items():
            if key not in state[kind]:
                problems.append(f"declared {SINGULAR[kind]} missing in shelf: {entry['name']} (run sync)")
    for row in query('select "sequentialId" as id, title from "Asset" where "categoryId" is null'):
        problems.append(f"{row['id']} {row['title']}: no category")
    for field in taxonomy["fields"].values():
        if not field.get("required"):
            continue
        for row in query(f'select a."sequentialId" as id from "Asset" a join "_CategoryToCustomField" x on x."A" = a."categoryId" '
                         f'join "CustomField" f on f.id = x."B" and lower(f.name) = {literal(field["name"].lower())} '
                         f'where not exists (select 1 from "AssetCustomFieldValue" v where v."assetId" = a.id and v."customFieldId" = f.id)'):
            problems.append(f"{row['id']}: required field '{field['name']}' is empty")
    return problems


def product_image(path):
    """Frames every product shot the same way: flattened on white, trimmed, centred in a square."""
    from PIL import Image, ImageChops, ImageOps

    with Image.open(path) as original:
        image = ImageOps.exif_transpose(original).convert("RGBA")
    flattened = Image.new("RGB", image.size, "white")
    flattened.paste(image, mask=image.getchannel("A"))
    whiten_background(flattened)
    difference = ImageChops.difference(flattened, Image.new("RGB", image.size, "white")).convert("L")
    content = difference.point(lambda level: 255 if level > 12 else 0).getbbox()
    if content:
        flattened = flattened.crop(content)
    side = int(max(flattened.size) * (1 + 2 * PRODUCT_IMAGE_MARGIN))
    square = Image.new("RGB", (side, side), "white")
    square.paste(flattened, ((side - flattened.width) // 2, (side - flattened.height) // 2))
    return square.resize((PRODUCT_IMAGE_SIZE, PRODUCT_IMAGE_SIZE), Image.LANCZOS) if side > PRODUCT_IMAGE_SIZE else square


def whiten_background(image):
    """Turns an off-white studio background pure white, filling from the corners so a white product stays intact."""
    from PIL import ImageDraw

    for corner in ((0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)):
        if min(image.getpixel(corner)) >= 225:
            ImageDraw.floodfill(image, corner, (255, 255, 255), thresh=16)


def upload_image(path, user_id, asset_id, config):
    """Stores a photo the way shelf does: main image plus a 108px thumbnail, both behind signed URLs."""
    from PIL import ImageOps

    stamp = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    base = f"{user_id}/{asset_id}/main-image-{stamp}"
    image = product_image(path)
    main, thumb = io.BytesIO(), io.BytesIO()
    image.save(main, "JPEG", quality=90)
    ImageOps.fit(image, (THUMBNAIL_SIZE, THUMBNAIL_SIZE)).save(thumb, "JPEG", quality=85)
    urls = [storage_upload_and_sign(f"{base}.jpg", main.getvalue(), config),
            storage_upload_and_sign(f"{base}-thumbnail.jpg", thumb.getvalue(), config)]
    return urls[0], urls[1]


def image_columns_sql(main_image, thumb):
    return (f'"mainImage" = {literal(main_image)}, "thumbnailImage" = {literal(thumb)}, '
            f'"mainImageExpiration" = now() + interval \'1 day\'')


def storage_upload_and_sign(object_path, data, config):
    base = config["SUPABASE_URL"].rstrip("/") + "/storage/v1"
    headers = {"Authorization": f"Bearer {config['SERVICE_ROLE_KEY']}", "apikey": config["SERVICE_ROLE_KEY"]}
    upload = urllib.request.Request(f"{base}/object/assets/{object_path}", data=data, method="POST",
                                    headers={**headers, "Content-Type": "image/jpeg", "x-upsert": "true"})
    urllib.request.urlopen(upload).read()
    sign = urllib.request.Request(f"{base}/object/sign/assets/{object_path}", method="POST",
                                  data=json.dumps({"expiresIn": 86400}).encode(),
                                  headers={**headers, "Content-Type": "application/json"})
    return base + json.loads(urllib.request.urlopen(sign).read())["signedURL"]


def user_link(ws):
    return f'{{% link to="/settings/team/users/{ws["user"]}" text="{ws["userName"]}" /%}}'


def validate_asset(asset, taxonomy, need_id):
    unknown = set(asset) - ASSET_KEYS
    label = asset.get("id") or asset.get("title", "<untitled>")
    if unknown:
        raise CatalogError(f"{label}: unknown keys {sorted(unknown)}")
    if need_id and not asset.get("id"):
        raise CatalogError(f"{label}: update entries need id = \"SAM-....\"")
    if not need_id and (not asset.get("title") or not asset.get("category")):
        raise CatalogError(f"{label}: new assets need a title and a category")
    if not need_id and not asset.get("model"):
        raise CatalogError(f"{label}: new assets need a model; declare one under [[models]] first")
    category = require(taxonomy, "categories", asset["category"], label) if asset.get("category") else None
    if asset.get("model"):
        model = require(taxonomy, "models", asset["model"], label)
        if category and model["category"].lower() != category["name"].lower():
            raise CatalogError(f"{label}: model '{model['name']}' belongs to {model['category']}, not {category['name']}")
    if asset.get("location"):
        require(taxonomy, "locations", asset["location"], label)
    for tag in asset.get("tags", []):
        require(taxonomy, "tags", tag, label)
    for name, raw in asset.get("fields", {}).items():
        field = require(taxonomy, "fields", name, label)
        scoped = [c.lower() for c in field.get("categories", [])]
        if category and scoped and category["name"].lower() not in scoped:
            raise CatalogError(f"{label}: field '{field['name']}' does not apply to {category['name']}")
        if raw != "":
            field_value_json(field, raw)
    if not need_id and category:
        for field in taxonomy["fields"].values():
            scoped = [c.lower() for c in field.get("categories", [])]
            applies = not scoped or category["name"].lower() in scoped
            given = {k.lower() for k in asset.get("fields", {})}
            if field.get("required") and applies and field["name"].lower() not in given:
                raise CatalogError(f"{label}: required field '{field['name']}' is missing")
    if asset.get("image") and not os.path.isfile(asset["image"]):
        raise CatalogError(f"{label}: image {asset['image']} not found")


def field_upsert_sql(asset_id, field_id, value_json):
    return (f'delete from "AssetCustomFieldValue" where "assetId" = {asset_id} and "customFieldId" = {literal(field_id)};\n'
            f'insert into "AssetCustomFieldValue" (id, value, "assetId", "customFieldId", "updatedAt") '
            f'values ({literal(new_id())}, {literal(json.dumps(value_json))}::jsonb, {asset_id}, {literal(field_id)}, now());\n')


def asset_body_sql(asset, asset_id, state, taxonomy, ws):
    """SQL for everything an add or update may set besides the asset's own columns."""
    sql = []
    if asset.get("location"):
        location_id = literal(state["locations"][asset["location"].lower()]["id"])
        sql.append(f'delete from "AssetLocation" where "assetId" = {asset_id};\n'
                   f'insert into "AssetLocation" (id, "assetId", "locationId", "organizationId", quantity, "updatedAt") '
                   f'values ({literal(new_id())}, {asset_id}, {location_id}, {literal(ws["org"])}, 1, now());\n')
    if "tags" in asset:
        sql.append(f'delete from "_AssetToTag" where "A" = {asset_id};\n')
        for tag in asset["tags"]:
            sql.append(f'insert into "_AssetToTag" ("A", "B") values ({asset_id}, {literal(state["tags"][tag.lower()]["id"])});\n')
    for name, raw in asset.get("fields", {}).items():
        field = taxonomy["fields"][name.lower()]
        field_id = state["fields"][name.lower()]["id"]
        if raw == "":
            sql.append(f'delete from "AssetCustomFieldValue" where "assetId" = {asset_id} and "customFieldId" = {literal(field_id)};\n')
        else:
            sql.append(field_upsert_sql(asset_id, field_id, field_value_json(field, raw)))
    return "".join(sql)


def add_assets(batch, taxonomy, ws, config):
    for asset in batch:
        validate_asset(asset, taxonomy, need_id=False)
    state = db_state()
    missing = [f"{SINGULAR[kind]} {name}" for kind in ("categories", "tags", "locations", "models", "fields")
               for name in taxonomy[kind] if name not in state[kind]]
    if missing:
        raise CatalogError(f"shelf is missing declared {', '.join(missing)}; run sync first")
    created = []
    for asset in batch:
        asset_uuid = new_id()
        asset_id = literal(asset_uuid)
        model = state["models"][asset["model"].lower()] if asset.get("model") else None
        main_image = thumb = expiry = None
        image_path = asset.get("image") or model_image_path(taxonomy["models"][asset["model"].lower()])
        if image_path:
            main_image, thumb = upload_image(image_path, ws["user"], asset_uuid, config)
            expiry = "now() + interval '1 day'"
        sql = [f"select get_next_sequential_id({literal(ws['org'])}) as id \\gset\n",
               f'insert into "Asset" (id, title, description, "sequentialId", "userId", "organizationId", "categoryId", "assetModelId", '
               f'value, "mainImage", "thumbnailImage", "mainImageExpiration", "updatedAt") values ({asset_id}, {literal(asset["title"])}, '
               f'{literal(asset.get("description"))}, :\'id\', {literal(ws["user"])}, {literal(ws["org"])}, '
               f'{literal(state["categories"][asset["category"].lower()]["id"])}, {literal(model["id"]) if model else "null"}, '
               f'{literal(asset.get("value"))}, {literal(main_image)}, {literal(thumb)}, {expiry or "null"}, now());\n',
               f'insert into "Qr" (id, version, "errorCorrection", "assetId", "userId", "organizationId", "updatedAt") '
               f'values ({literal(new_qr_id())}, 0, \'L\', {asset_id}, {literal(ws["user"])}, {literal(ws["org"])}, now());\n',
               asset_body_sql(asset, asset_id, state, taxonomy, ws),
               f'insert into "Note" (id, content, type, "userId", "assetId", "updatedAt") values ({literal(new_id())}, '
               f'{literal("Asset was created by " + user_link(ws) + ".")}, \'UPDATE\', {literal(ws["user"])}, {asset_id}, now());\n',
               f"select json_build_object('id', :'id');\n"]
        result = run_sql("".join(sql), want_rows=True)
        created.append(f"+ {result['id']} {asset['title']}")
    return created


def update_assets(batch, taxonomy, ws, config):
    for asset in batch:
        validate_asset(asset, taxonomy, need_id=True)
    state = db_state()
    updated = []
    for asset in batch:
        rows = query(f'select a.id, a.title, c.name as category from "Asset" a left join "Category" c on c.id = a."categoryId" '
                     f'where a."sequentialId" = {literal(asset["id"])}')
        if not rows:
            raise CatalogError(f"{asset['id']}: no such asset")
        if not asset.get("category") and rows[0]["category"]:
            validate_asset({**asset, "category": rows[0]["category"]}, taxonomy, need_id=True)
        asset_uuid = rows[0]["id"]
        asset_id = literal(asset_uuid)
        columns, changed = [], []
        for key, column in (("title", "title"), ("description", "description"), ("value", "value")):
            if key in asset:
                columns.append(f'{column} = {literal(asset[key] if asset[key] != "" else None)}')
                changed.append(key)
        if "category" in asset:
            columns.append(f'"categoryId" = {literal(state["categories"][asset["category"].lower()]["id"])}')
            changed.append("category")
        if "model" in asset:
            model_id = literal(state["models"][asset["model"].lower()]["id"]) if asset["model"] else "null"
            columns.append(f'"assetModelId" = {model_id}')
            changed.append("model")
        if asset.get("image"):
            main_image, thumb = upload_image(asset["image"], ws["user"], asset_uuid, config)
            columns.append(image_columns_sql(main_image, thumb))
            changed.append("image")
        changed += [k for k in ("location", "tags") if k in asset]
        changed += [f"field {name}" for name in asset.get("fields", {})]
        sql = []
        if columns:
            sql.append(f'update "Asset" set {", ".join(columns)}, "updatedAt" = now() where id = {asset_id};\n')
        sql.append(asset_body_sql(asset, asset_id, state, taxonomy, ws))
        sql.append(f'update "Asset" set "updatedAt" = now() where id = {asset_id};\n')
        sql.append(f'insert into "Note" (id, content, type, "userId", "assetId", "updatedAt") values ({literal(new_id())}, '
                   f'{literal(user_link(ws) + " updated " + ", ".join(changed) + " through the catalog.")}, \'UPDATE\', '
                   f'{literal(ws["user"])}, {asset_id}, now());\n')
        run_sql("".join(sql))
        updated.append(f"~ {asset['id']} {asset.get('title', rows[0]['title'])}: {', '.join(changed)}")
    return updated


def apply_model_images(taxonomy, ws, config):
    """Gives every asset its model's product shot, replacing whatever image it had."""
    rows = query('select a.id, a."sequentialId" as sid, a.title, m.name as model from "Asset" a '
                 'join "AssetModel" m on m.id = a."assetModelId" order by a."sequentialId"')
    applied, without_image = [], set()
    for row in rows:
        model = taxonomy["models"].get(row["model"].lower())
        if not model or not model.get("image"):
            without_image.add(row["model"])
            continue
        main_image, thumb = upload_image(model_image_path(model), ws["user"], row["id"], config)
        run_sql(f'update "Asset" set {image_columns_sql(main_image, thumb)}, "updatedAt" = now() where id = {literal(row["id"])};\n'
                f'insert into "Note" (id, content, type, "userId", "assetId", "updatedAt") values ({literal(new_id())}, '
                f'{literal(user_link(ws) + " set the model product image through the catalog.")}, \'UPDATE\', '
                f'{literal(ws["user"])}, {literal(row["id"])}, now());\n')
        applied.append(f"~ {row['sid']} {row['title']}: image from data/{model['image']}")
    return applied + [f"! model without image: {name}" for name in sorted(without_image)] or ["no assets have a model"]


def cutout(photo, output):
    """Cuts the item out of a phone photo with rembg in Docker, turns it straight and saves a transparent PNG."""
    import tempfile
    from PIL import Image, ImageOps

    if not os.path.isfile(photo):
        raise CatalogError(f"{photo} not found")
    with tempfile.TemporaryDirectory() as work:
        with Image.open(photo) as original:
            ImageOps.exif_transpose(original).convert("RGB").save(os.path.join(work, "in.png"))
        command = ["docker", "run", "--rm", "-e", "U2NET_HOME=/models", "-v", "shelf-rembg-models:/models",
                   "-v", f"{work}:/work", CUTOUT_IMAGE, "i", "-m", CUTOUT_MODEL, "/work/in.png", "/work/out.png"]
        result = subprocess.run(command, capture_output=True)
        if result.returncode != 0:
            raise CatalogError("rembg failed: " + result.stderr.decode("utf-8", "replace").strip()[-800:])
        with Image.open(os.path.join(work, "out.png")) as cut:
            straight = straighten(cut.convert("RGBA"))
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    straight.save(output)
    return [f"+ {output} ({straight.width}x{straight.height})"]


def straighten(image):
    """Rotates a cut-out to the angle with the tightest bounding box, long side horizontal, and crops to it."""
    from PIL import Image

    preview = image.getchannel("A").point(lambda level: 255 if level > 128 else 0)
    preview.thumbnail((400, 400))

    def box_area(angle):
        box = preview.rotate(angle, expand=True).getbbox()
        return (box[2] - box[0]) * (box[3] - box[1]) if box else float("inf")

    coarse = min(range(-45, 46, 3), key=box_area)
    best = min((coarse + step / 4 for step in range(-12, 13)), key=box_area)
    rotated = image.rotate(best, expand=True, resample=Image.BICUBIC)
    rotated = rotated.crop(rotated.getchannel("A").point(lambda level: 255 if level > 128 else 0).getbbox())
    return rotated.rotate(90, expand=True) if rotated.height > rotated.width else rotated


def ring_slots():
    """Places labels radially around a ring, in as many circles as fit between the hole and the edge.

    Each slot is (inner radius, angle in degrees). Radially placed labels only spread apart outwards,
    so neighbours are spaced by their inner corners and the next circle starts beyond the outer corners.
    """
    width, height = LABEL_SIZE_MM
    radius = RING_HOLE_RADIUS_MM + RING_SAFETY_MM
    limit = RING_OUTER_RADIUS_MM - RING_SAFETY_MM
    slots = []
    while math.hypot(radius + height, width / 2) <= limit:
        pitch = 2 * math.degrees(math.atan((width + LABEL_GAP_MM) / 2 / radius))
        count = int(360 // pitch)
        slots += [(radius, 90 - index * 360 / count) for index in range(count)]
        radius = math.hypot(radius + height, width / 2) + LABEL_GAP_MM
    return slots


def label_assets(wanted_ids):
    rows = query('select distinct on (a."sequentialId") a."sequentialId" as id, q.id as qr from "Asset" a '
                 'join "Qr" q on q."assetId" = a.id order by a."sequentialId", q."createdAt"')
    if not wanted_ids:
        return rows
    found = {row["id"]: row for row in rows}
    missing = [asset_id for asset_id in wanted_ids if asset_id not in found]
    if missing:
        raise CatalogError(f"no asset with a QR code: {', '.join(missing)}")
    return [found[asset_id] for asset_id in wanted_ids]


def qr_modules(url):
    try:
        import segno
    except ImportError:
        raise CatalogError("labels needs segno: python -m pip install segno")
    return segno.make(url, error="l", boost_error=False).matrix


def label_drawing(asset_id, modules):
    """PDF operators for one label in its own frame: x across, y outwards from the ring centre, in mm."""
    width, height = LABEL_SIZE_MM
    pad = LABEL_PADDING_MM
    text_width = sum(HELVETICA_BOLD_WIDTHS.get(char, 600) for char in asset_id) / 1000 * LABEL_TEXT_SIZE_MM
    text_top = pad + 0.75 * LABEL_TEXT_SIZE_MM
    side = min(width - 2 * pad, height - text_top - pad - 0.4)
    module = side / (len(modules) + 2 * QR_QUIET_MODULES)
    left = -side / 2 + QR_QUIET_MODULES * module
    top = height - pad - QR_QUIET_MODULES * module
    operators = [f"0.1 w 0.6 G {-width / 2:.3f} 0 {width:.3f} {height:.3f} re S", "0 g"]
    for row_index, row in enumerate(modules):
        y = top - (row_index + 1) * module
        for start, length in dark_runs(row):
            operators.append(f"{left + start * module:.3f} {y:.3f} {length * module:.3f} {module:.3f} re")
    operators.append("f")
    operators.append(f"BT /F1 {LABEL_TEXT_SIZE_MM} Tf {-text_width / 2:.3f} {pad + 0.2:.3f} Td ({asset_id}) Tj ET")
    return "\n".join(operators)


def dark_runs(row):
    runs, start = [], None
    for index, dark in enumerate(list(row) + [0]):
        if dark and start is None:
            start = index
        elif not dark and start is not None:
            runs.append((start, index - start))
            start = None
    return runs


def circle_path(x, y, radius):
    k = 0.5523 * radius
    return (f"{x + radius:.3f} {y:.3f} m {x + radius:.3f} {y + k:.3f} {x + k:.3f} {y + radius:.3f} {x:.3f} {y + radius:.3f} c "
            f"{x - k:.3f} {y + radius:.3f} {x - radius:.3f} {y + k:.3f} {x - radius:.3f} {y:.3f} c "
            f"{x - radius:.3f} {y - k:.3f} {x - k:.3f} {y - radius:.3f} {x:.3f} {y - radius:.3f} c "
            f"{x + k:.3f} {y - radius:.3f} {x + radius:.3f} {y - k:.3f} {x + radius:.3f} {y:.3f} c S")


def sheet_content(placed, outline):
    """One page: every (ring centre, slot, drawing) placed, with y flipped so centres read from the top-left."""
    points_per_mm = 72 / 25.4
    operators = [f"{points_per_mm:.6f} 0 0 {points_per_mm:.6f} 0 0 cm"]
    if outline:
        operators.append("0.2 w 0 G [1 1] 0 d")
        for centre_x, centre_y in RING_CENTRES_MM:
            for radius in (RING_OUTER_RADIUS_MM, RING_HOLE_RADIUS_MM):
                operators.append(circle_path(centre_x, PAGE_SIZE_MM[1] - centre_y, radius))
        operators.append("[] 0 d")
    for (centre_x, centre_y), (radius, angle), drawing in placed:
        cos, sin = math.cos(math.radians(angle)), math.sin(math.radians(angle))
        origin_x = centre_x + cos * radius
        origin_y = PAGE_SIZE_MM[1] - centre_y + sin * radius
        operators.append(f"q {sin:.6f} {-cos:.6f} {cos:.6f} {sin:.6f} {origin_x:.3f} {origin_y:.3f} cm\n{drawing}\nQ")
    return "\n".join(operators)


def pdf_document(pages):
    """A minimal PDF: one Helvetica-Bold font and one uncompressed content stream per page."""
    width, height = (size * 72 / 25.4 for size in PAGE_SIZE_MM)
    page_ids = [4 + 2 * index for index in range(len(pages))]
    objects = {
        1: "<< /Type /Catalog /Pages 2 0 R >>",
        2: f"<< /Type /Pages /Kids [{' '.join(f'{page_id} 0 R' for page_id in page_ids)}] /Count {len(pages)} >>",
        3: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
    }
    for page_id, content in zip(page_ids, pages):
        objects[page_id] = (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width:.2f} {height:.2f}] "
                            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {page_id + 1} 0 R >>")
        objects[page_id + 1] = f"<< /Length {len(content.encode('latin-1'))} >>\nstream\n{content}\nendstream"
    output = b"%PDF-1.4\n"
    offsets = {}
    for object_id in sorted(objects):
        offsets[object_id] = len(output)
        output += f"{object_id} 0 obj\n{objects[object_id]}\nendobj\n".encode("latin-1")
    xref = len(output)
    output += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("latin-1")
    output += "".join(f"{offsets[object_id]:010d} 00000 n \n" for object_id in sorted(objects)).encode("latin-1")
    output += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("latin-1")
    return output


def print_labels(wanted_ids, output, outline, config):
    """Writes ring-shaped label sheets: every asset's ID and shelf QR code, placed to be cut apart."""
    slots = [(centre, slot) for centre in RING_CENTRES_MM for slot in ring_slots()]
    assets = label_assets(wanted_ids)
    server_url = config["SERVER_URL"].rstrip("/")
    pages = []
    for first in range(0, len(assets), len(slots)):
        batch = assets[first:first + len(slots)]
        placed = [(centre, slot, label_drawing(asset["id"], qr_modules(f"{server_url}/qr/{asset['qr']}")))
                  for (centre, slot), asset in zip(slots, batch)]
        pages.append(sheet_content(placed, outline))
    if not pages:
        raise CatalogError("no assets to label")
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with open(output, "wb") as handle:
        handle.write(pdf_document(pages))
    return [f"+ {output}: {len(assets)} labels on {len(pages)} sheet(s), {len(slots)} per sheet; print at actual size"]


def list_assets():
    rows = query('select a."sequentialId" as id, a.title, c.name as category, m.name as model, l.name as location, a.value, '
                 'coalesce((select string_agg(t.name, \', \' order by t.name) from "_AssetToTag" x join "Tag" t on t.id = x."B" where x."A" = a.id), \'\') as tags, '
                 'coalesce((select string_agg(f.name || \'=\' || (v.value->>\'raw\'), \'; \' order by f.name) from "AssetCustomFieldValue" v '
                 'join "CustomField" f on f.id = v."customFieldId" where v."assetId" = a.id), \'\') as fields '
                 'from "Asset" a left join "Category" c on c.id = a."categoryId" left join "AssetModel" m on m.id = a."assetModelId" '
                 'left join "AssetLocation" al on al."assetId" = a.id left join "Location" l on l.id = al."locationId" order by a."sequentialId"')
    return [f"{r['id']}  {r['title']}\n    {r['category']} / {r['model'] or '-'} @ {r['location'] or '-'}  value {r['value']}\n"
            f"    tags: {r['tags'] or '-'}\n    fields: {r['fields'] or '-'}" for r in rows]


def main():
    parser = argparse.ArgumentParser(prog="docker-compose.ps1 catalog")
    parser.add_argument("command", choices=["check", "sync", "add", "update", "list", "images", "cutout", "labels"])
    parser.add_argument("file", nargs="?", help="batch file for add / update, photo for cutout, PDF to write for labels")
    parser.add_argument("output", nargs="?", help="cutout: the transparent PNG to write, e.g. data/images/<model>.png")
    parser.add_argument("--prune", action="store_true", help="sync: also delete undeclared, unused taxonomy")
    parser.add_argument("--ids", help="labels: only these assets, comma separated, e.g. SAM-0001,SAM-0007")
    parser.add_argument("--outline", action="store_true", help="labels: also draw the ring edges, for a test print")
    arguments = parser.parse_args()
    try:
        if arguments.command == "list":
            lines = list_assets()
        elif arguments.command == "labels":
            wanted_ids = [part.strip() for part in arguments.ids.split(",")] if arguments.ids else []
            lines = print_labels(wanted_ids, arguments.file or LABELS_PATH, arguments.outline, read_config())
        elif arguments.command == "cutout":
            if not arguments.file or not arguments.output:
                raise CatalogError("cutout needs a photo and an output path")
            lines = cutout(arguments.file, arguments.output)
        else:
            taxonomy = load_catalog()
            if arguments.command == "check":
                lines = check(taxonomy)
                print("\n".join(lines) if lines else "catalog and shelf agree")
                return 1 if lines else 0
            ws = workspace()
            if arguments.command == "sync":
                lines = sync(taxonomy, ws, arguments.prune)
            elif arguments.command == "images":
                lines = apply_model_images(taxonomy, ws, read_config())
            else:
                if not arguments.file:
                    raise CatalogError(f"{arguments.command} needs a batch file")
                batch = load_toml(arguments.file).get("assets", [])
                if not batch:
                    raise CatalogError(f"{arguments.file} has no [[assets]] entries")
                handler = add_assets if arguments.command == "add" else update_assets
                lines = handler(batch, taxonomy, ws, read_config())
        print("\n".join(lines))
        return 0
    except CatalogError as error:
        print(f"catalog: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
