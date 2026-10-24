# immich

Self-hosted photo and video library ([immich.app](https://immich.app)), based
on the official v3.3.5 compose file. The header of
[docker-compose.yml](docker-compose.yml) lists what differs from upstream.

| | |
|---|---|
| UI / mobile app | `http://<host>.local:2283` |
| Containers | `immich_server`, `immich_postgres`, `immich_redis`, `immich_machine_learning` (only with the `ml` profile) |
| Photos | `${UPLOAD_LOCATION}` (default `/srv/immich/library`) |
| Database | `${DB_DATA_LOCATION}` (default `/srv/immich/postgres`), local disk only, never a network share |
| Requirements | 6 GB RAM minimum (8 GB recommended) with ML; around 4 GB with ML off |

## Settings

| Key (stack.env) | host.env / secrets key | Meaning |
|---|---|---|
| `TZ` | `TZ` (global) | Fallback time zone for photos without one, plus logs and cron |
| `UPLOAD_LOCATION` | `IMMICH__UPLOAD_LOCATION` | Photos, videos, thumbnails, database dumps |
| `DB_DATA_LOCATION` | `IMMICH__DB_DATA_LOCATION` | Postgres data |
| `DB_STORAGE_TYPE` | `IMMICH__DB_STORAGE_TYPE` | `HDD` or `SSD`, matching the disk under `DB_DATA_LOCATION` |
| `COMPOSE_PROFILES` | `IMMICH__COMPOSE_PROFILES` | `ml` runs machine learning; empty turns it off |
| `DB_PASSWORD` | `IMMICH__DB_PASSWORD` (**secrets**) | Postgres password. **Letters and digits only** (`A-Za-z0-9`); special characters break Immich. |
| `DB_USERNAME`, `DB_DATABASE_NAME` | `IMMICH__…` | Leave as `postgres` / `immich` |

The DB password is randomly generated and only lives in `secrets.sops.env`. You
never type it anywhere: Immich and Postgres both read it from `stack.env`.

## First run

1. With `immich` in `STACKS` and the settings above in place, run bootstrap.
   It creates the data directories and registers the stack.
2. Open `http://<host>.local:2283` and create the admin account. Save it in
   your password manager; it's separate from Portainer and Omada.
3. **If ML is off** (`COMPOSE_PROFILES` empty): go to Administration →
   Settings → Machine Learning and turn it off. Otherwise Immich keeps queuing
   face and smart-search jobs for a container that isn't running.
4. Check Administration → Settings → **Database Dump Settings**: enabled, daily,
   keep 14 (the defaults).
5. **Mobile app:** the server URL is `http://<host>.local:2283`. iPhones resolve
   `.local`; many Android phones don't, so use the host's IP there. If the IP
   ever changes, update it in the app. (This gets fixed for good with a router
   that does DHCP reservations.)

Access from outside your home network isn't set up. That's a separate decision
(VPN such as Tailscale, or a reverse proxy) for later.

### Turning machine learning on or off later

Set `IMMICH__COMPOSE_PROFILES=ml` (on) or empty (off) in `host.env`, merge,
then on the host run `sudo git pull && sudo ./bootstrap.sh <host>`.

- **Turning it on:** also enable it in Administration → Settings → Machine
  Learning, then run the Smart Search and Face Detection jobs for all assets
  (Administration → Job Queues). On the 2011 Mac mini, expect the first pass
  over a large library to take a long time.
- **Turning it off:** compose won't remove a container whose profile was
  dropped, so remove it yourself:
  `docker rm -f immich_machine_learning`.

### Optional: external library (read-only)

To index existing photos without Immich copying or changing them:

1. Uncomment and adjust the example `volumes` line under `immich-server` in
   [docker-compose.yml](docker-compose.yml), keeping `:ro`. For example,
   `/mnt/media/photos:/mnt/external/photos:ro`.
2. Merge. Portainer redeploys within 5 minutes.
3. In Immich: Administration → External Libraries → Create, with import path
   `/mnt/external/photos`.

## Upgrades

Renovate opens **one** PR that bumps the server and ML images together (their
versions must match).

1. Read the [release notes](https://github.com/immich-app/immich/releases),
   especially "breaking changes".
2. Compare the release's `docker-compose.yml` with ours:
   `https://github.com/immich-app/immich/releases/download/<version>/docker-compose.yml`.
   If upstream changed anything besides the image tags (most often the
   Postgres or Valkey image), copy that change into the PR, keeping the
   differences listed in our file's header.
3. For a major version, trigger a fresh dump first: Administration → Job
   Queues → Create job → Create Database Dump.
4. Merge. Portainer redeploys within 5 minutes, and Immich migrates its database
   on startup.

Renovate never changes the Postgres image tag on its own: a Postgres version
change needs a data migration, so it only happens when upstream's compose file
does it, via step 2.

## Backups

What matters, all under `UPLOAD_LOCATION`:

| Path | What | Back up? |
|---|---|---|
| `library/`, `upload/`, `profile/` | Original photos/videos, avatars | **Yes**, irreplaceable |
| `backups/` | Immich's daily database dumps (2 AM, keeps 14) | **Yes**: albums, faces, metadata |
| `thumbs/`, `encoded-video/` | Generated thumbnails and transcodes | Optional (regenerable) |

`DB_DATA_LOCATION` itself does **not** need backing up: the dumps in `backups/`
are the database backup, and copying live Postgres files is unreliable anyway.

For now, everything sits on one HDD in the Mac mini with **no off-box copy**.
A disk failure would lose everything. The next step is a restic backup stack
that copies `UPLOAD_LOCATION` (minus `thumbs/` and `encoded-video/`) to an
off-box target. That's pending a choice of target (USB drive and/or Backblaze
B2).

## Restore

On a fresh host, or after losing the database:

1. **Put the files back.** Restore `library/`, `upload/`, `profile/` and
   `backups/` into `UPLOAD_LOCATION`.
2. **Deploy the stack** with bootstrap as usual. Let it start.
3. **Stop the server** so it can't touch the database during the restore, and
   reset Postgres to an empty data directory:
   ```bash
   docker stop immich_server immich_postgres
   sudo rm -rf /srv/immich/postgres/*        # your DB_DATA_LOCATION
   docker start immich_postgres && sleep 15  # re-initializes an empty DB
   ```
4. **Load the newest dump** (from Immich's documented restore procedure):
   ```bash
   DUMP=$(ls -t /srv/immich/library/backups/*.sql.gz | head -n 1)
   gunzip --stdout "$DUMP" \
     | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
     | docker exec -i immich_postgres psql --dbname=immich --username=postgres --single-transaction --set ON_ERROR_STOP=on
   ```
5. **Start the server:** `docker start immich_server`. Restore into the same or
   a newer Immich version than the dump came from.

Immich also offers a restore from the web UI on a fresh install
([docs](https://docs.immich.app/administration/backup-and-restore)), which is
fine for a simple case.
