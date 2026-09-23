# shelf-compose

Self-hosted [shelf.nu](https://github.com/Shelf-nu/shelf.nu) asset management in Docker, with its own Supabase (Postgres, Auth, Storage), mail catcher and hourly backups instead of Supabase Cloud.

[shelf.nu](https://github.com/Shelf-nu/shelf.nu) needs Supabase for its database, logins and file
uploads. Upstream's Docker image expects Supabase Cloud; this stack runs the parts shelf actually
uses on your own machine instead, so nothing leaves it.

## Stack

| service | image | role |
| --- | --- | --- |
| `shelf` | `ghcr.io/shelf-nu/shelf.nu:2.2.0` | the app, on `:3000` |
| `db` | `supabase/postgres:17.6.1.136` | Postgres with Supabase's roles and schemas |
| `auth` | `supabase/gotrue:v2.196.0` | Supabase Auth, set up for shelf's 6-digit email codes |
| `storage` | `supabase/storage-api:v1.74.0` | file storage, kept in `data/storage` |
| `gateway` | `nginx:1.29.8-alpine` | the one Supabase URL on `:8000`, plus the email templates |
| `mail` | `axllent/mailpit:v1.31.2` | catches every email; read them at `:8025` |
| `migrate` | built from `shelf@2.2.0` | applies shelf's database migrations, then exits |
| `init` | `curlimages/curl:8.16.0` | creates the four storage buckets shelf expects, then exits |
| `db-backup` | `supabase/postgres:17.6.1.136` | hourly database dumps into `data/backups` |

Every image is pinned to a version, and the migrations come from the same release tag as the app.

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/) and PowerShell (built into Windows; `pwsh`
elsewhere).

```powershell
git clone --recursive https://github.com/intisy-compose/shelf-compose
cd shelf-compose

.\docker-compose.ps1 init-config   # creates config.env and generates every secret and key
.\docker-compose.ps1 up            # the one CLI; `.\docker-compose.ps1 help` lists every command
```

Open http://localhost:3000 and sign up. The confirmation code arrives in Mailpit at
http://localhost:8025, because nothing is sent to real inboxes until you configure SMTP.

## Configuration

`config.env` (gitignored) holds everything; `config.env.example` documents each value.

- **Real email:** set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` and `SMTP_FROM`. Port 465
  uses TLS, any other port plain SMTP. Both shelf and Supabase Auth send through it.
- **Other machines:** replace `localhost` in `SERVER_URL` and `SUPABASE_URL` with this host's LAN
  address or domain. The browser loads images and talks to Auth through `SUPABASE_URL`, so it has
  to be reachable from wherever shelf is opened.
- **Ports:** `SHELF_PORT`, `SUPABASE_PORT` and `MAILPIT_PORT`. Keep `SERVER_URL` and
  `SUPABASE_URL` in step with them.
- **Maps:** shelf requires `MAPTILER_TOKEN`; the placeholder keeps it running with maps blank. Set
  a [MapTiler](https://www.maptiler.com/) token to enable them.
- **Sign-ups:** `DISABLE_SIGNUP=true` closes registration once your team has joined.

`ANON_KEY` and `SERVICE_ROLE_KEY` are signed with `JWT_SECRET`. `init-config` only fills values that
are empty, so to rotate them, blank all three and run it again.

## Data and backups

The database lives in the Docker volume `shelf_shelf-db`, because Postgres on a Windows bind mount
fails on file permissions. `db-backup` dumps it every hour into `data/backups` and keeps the newest
`BACKUP_KEEP` (48 by default). Restore with:

```powershell
.\docker-compose.ps1 restore                          # the newest dump
.\docker-compose.ps1 restore shelf-20260923-091920.dump
```

`data/` is its own git repo (a submodule), defaulting to the public
[`shelf-data-template`](https://github.com/intisy-compose/shelf-data-template). Point it at your
own with `.\docker-compose.ps1 data use <owner/repo[@ref]>`. The dumps and uploaded files are
gitignored there.

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
