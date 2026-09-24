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
import os
import secrets
import string
import subprocess
import sys
import tomllib
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_PATH = os.path.join(ROOT, "data", "catalog.toml")
CONFIG_PATH = os.path.join(ROOT, "config.env")
FIELD_TYPES = {"TEXT", "NUMBER", "AMOUNT", "OPTION", "BOOLEAN", "DATE", "MULTILINE_TEXT"}
ASSET_KEYS = {"id", "title", "description", "category", "model", "location", "tags", "fields", "value", "image"}
THUMBNAIL_SIZE = 108
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
    return taxonomy


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
    sql, report = [], []
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


def check(taxonomy):
    state, problems = db_state(), []
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


def upload_image(path, user_id, asset_id, config):
    """Stores a photo the way shelf does: main image plus a 108px thumbnail, both behind signed URLs."""
    from PIL import Image, ImageOps

    stamp = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    base = f"{user_id}/{asset_id}/main-image-{stamp}"
    with Image.open(path) as image:
        image = ImageOps.exif_transpose(image).convert("RGB")
        main, thumb = io.BytesIO(), io.BytesIO()
        image.save(main, "JPEG", quality=90)
        ImageOps.fit(image, (THUMBNAIL_SIZE, THUMBNAIL_SIZE)).save(thumb, "JPEG", quality=85)
    urls = [storage_upload_and_sign(f"{base}.jpg", main.getvalue(), config),
            storage_upload_and_sign(f"{base}-thumbnail.jpg", thumb.getvalue(), config)]
    return urls[0], urls[1]


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
        if asset.get("image"):
            main_image, thumb = upload_image(asset["image"], ws["user"], asset_uuid, config)
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
            columns.append(f'"mainImage" = {literal(main_image)}, "thumbnailImage" = {literal(thumb)}, '
                           f'"mainImageExpiration" = now() + interval \'1 day\'')
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
    parser.add_argument("command", choices=["check", "sync", "add", "update", "list"])
    parser.add_argument("file", nargs="?", help="batch file for add / update")
    parser.add_argument("--prune", action="store_true", help="sync: also delete undeclared, unused taxonomy")
    arguments = parser.parse_args()
    try:
        if arguments.command == "list":
            lines = list_assets()
        else:
            taxonomy = load_catalog()
            if arguments.command == "check":
                lines = check(taxonomy)
                print("\n".join(lines) if lines else "catalog and shelf agree")
                return 1 if lines else 0
            ws = workspace()
            if arguments.command == "sync":
                lines = sync(taxonomy, ws, arguments.prune)
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
