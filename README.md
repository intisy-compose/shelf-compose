# shelf-compose

Self-hosted [shelf.nu](https://github.com/Shelf-nu/shelf.nu) asset management in Docker, with its own Supabase (Postgres, Auth, Storage), mail catcher and hourly backups instead of Supabase Cloud.

[shelf.nu](https://github.com/Shelf-nu/shelf.nu) needs Supabase for its database, logins and file
uploads. Upstream's Docker image expects Supabase Cloud; this stack runs the parts shelf actually
uses on your own machine instead, so nothing leaves it, and serves it over
[Tailscale](https://tailscale.com/) with real HTTPS to every device on your tailnet.

## Stack

| service | image | role |
| --- | --- | --- |
| `tailscale` | `tailscale/tailscale:v1.102.4` | joins your tailnet as `shelf` and forwards `:443` and `:8443` |
| `gateway` | `caddy:2.11.4-alpine` | HTTPS for the `ts.net` name, with certificates from Tailscale |
| `shelf` | `ghcr.io/shelf-nu/shelf.nu:2.2.0` | the app, at `https://shelf.<tailnet>.ts.net` |
| `db` | `supabase/postgres:17.6.1.136` | Postgres with Supabase's roles and schemas |
| `auth` | `supabase/gotrue:v2.196.0` | Supabase Auth, set up for shelf's 6-digit email codes |
| `storage` | `supabase/storage-api:v1.74.0` | file storage, kept in `data/storage` |
| `mail` | `axllent/mailpit:v1.31.2` | catches every email; read them at `http://localhost:8025` |
| `migrate` | built from `shelf@2.2.0` | applies shelf's database migrations, then exits |
| `init` | `curlimages/curl:8.16.0` | creates the four storage buckets shelf expects, then exits |
| `db-backup` | `supabase/postgres:17.6.1.136` | hourly database dumps into `data/backups` |

Every image is pinned to a version, and the migrations come from the same release tag as the app.

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/), PowerShell (built into Windows; `pwsh`
elsewhere) and a Tailscale account with
[HTTPS certificates](https://tailscale.com/kb/1153/enabling-https) enabled.

```powershell
git clone --recursive https://github.com/intisy-compose/shelf-compose
cd shelf-compose

.\docker-compose.ps1 init-config   # creates config.env and generates every secret and key
# put an auth key from https://login.tailscale.com/admin/settings/keys into TS_AUTHKEY in config.env
.\docker-compose.ps1 up            # the one CLI; `.\docker-compose.ps1 help` lists every command
```

`up` joins the tailnet first, reads the node's real `ts.net` name and writes `SERVER_URL` and
`SUPABASE_URL` into `config.env` before starting the rest, then prints them. Open the shelf URL on
any device in your tailnet and sign up. The confirmation code arrives in Mailpit at
http://localhost:8025, because nothing is sent to real inboxes until you configure SMTP.

The auth key is only used for the first join; the node identity is kept in `data/tailscale`
afterwards, so an expired key does not matter once the node is in.

## Configuration

`config.env` (gitignored) holds everything; `config.env.example` documents each value.

- **Real email:** set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` and `SMTP_FROM`. Port 465
  uses TLS, any other port plain SMTP. Both shelf and Supabase Auth send through it.
- **Name:** `TS_HOSTNAME` (default `shelf`) is the node's name on the tailnet. shelf is served at
  `https://<TS_HOSTNAME>.<tailnet>.ts.net` and Supabase on `:8443` of the same name; both are
  tailnet-only, nothing is published to the internet.
- **How the URL works everywhere:** shelf's server calls `SUPABASE_URL` just like the browser does.
  shelf, Caddy and Tailscale share one network namespace, and inside it the `ts.net` name maps to
  `127.0.0.1`, so the server reaches Caddy directly with the same valid certificate.
- **Maps:** shelf requires `MAPTILER_TOKEN`; the placeholder keeps it running with maps blank. Set
  a [MapTiler](https://www.maptiler.com/) token to enable them.
- **Sign-ups:** `DISABLE_SIGNUP=true` closes registration once your team has joined.

`ANON_KEY` and `SERVICE_ROLE_KEY` are signed with `JWT_SECRET`. `init-config` only fills values that
are empty, so to rotate them, blank all three and run it again.

## Catalog

shelf lets anyone invent a category or tag on the spot, which is how inventories drift into
"Electronics" and half a dozen spellings of the same thing. The catalog tool keeps the structure
declared in one file instead:

- `data/catalog.toml` declares every category, custom field (with its type, options and the
  categories it applies to), tag, location and asset model the inventory may use.
- `.\docker-compose.ps1 catalog sync` makes shelf match it; `--prune` also removes undeclared ones
  that nothing uses.
- `.\docker-compose.ps1 catalog check` reports drift, for example after someone added a tag in the
  UI, and required fields left empty.
- `.\docker-compose.ps1 catalog add <batch.toml>` and `update <batch.toml>` create or change assets
  from a batch file. The whole batch is validated against the taxonomy before anything is written,
  so an undeclared category, tag, field or option is refused.
- `.\docker-compose.ps1 catalog list` prints every asset with its fields.

Assets written this way get what shelf's own "create asset" gives them: a sequential ID, a QR code,
their location, field values, an activity note, and optionally a photo with its thumbnail. The
tool mirrors shelf 2.2.0's services, so re-check it against shelf before moving to a newer version.
It needs Python 3.11 or newer on the host, plus [Pillow](https://pypi.org/project/pillow/) for
photos. The public data template ships a starter `catalog.toml` that shows the format.

## Data and backups

The database lives in the Docker volume `shelf_shelf-db`, because Postgres on a Windows bind mount
fails on file permissions. `db-backup` dumps it every hour into `data/backups` and keeps the newest
`BACKUP_KEEP` (48 by default). Take one on demand before a risky change, and restore with:

```powershell
.\docker-compose.ps1 backup                           # dump now
.\docker-compose.ps1 restore                          # the newest dump
.\docker-compose.ps1 restore shelf-20260923-091920.dump
```

`data/` is its own git repo (a submodule), defaulting to the public
[`shelf-data-template`](https://github.com/intisy-compose/shelf-data-template). Point it at your
own with `.\docker-compose.ps1 data use <owner/repo[@ref]>`. The dumps, uploaded files and the
Tailscale node identity (a secret) are gitignored there.

## Upgrading shelf

Change the `shelf` image tag and the `migrate` build's `shelf@<version>` tag in
`docker-compose.yml` together, then run `.\docker-compose.ps1 up`. The new migrations are applied
before shelf starts. Take a dump first; `restore` is the way back.

## Credits

`db/99-roles.sql` and `db/99-jwt.sql` come from Supabase's
[self-hosting setup](https://github.com/supabase/supabase/tree/master/docker) (Apache-2.0). The
email templates follow shelf's
[Supabase setup guide](https://github.com/Shelf-nu/shelf.nu/blob/main/apps/docs/supabase-setup.md).

## License

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
