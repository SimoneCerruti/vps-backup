# vps-backup

A small pure-bash tool for encrypted, deduplicated backups of a Docker VPS with [restic](https://restic.net).

It dumps the databases running in your containers, backs up Docker volumes and server configuration, applies retention, verifies the repository, logs everything and pings your monitoring. One command installs it on a new server.

## What it solves

You run several projects on one VPS: Laravel apps, WordPress sites, their databases, a reverse proxy, a few config files you tuned by hand. Each project may have its own backups, but nothing covers the server as a whole: the `.env` files, the compose files, the proxy and its certificates, the SSH and firewall hardening, the cron jobs.

`vps-backup` covers that with two modes:

| Mode    | Content                                                         | Default schedule        | Default retention |
|---------|-----------------------------------------------------------------|-------------------------|-------------------|
| `light` | Server and project configuration (+ selected small volumes)     | 03:00, Monday-Saturday  | last 14           |
| `full`  | Configuration + database dumps + Docker volumes                 | 03:00, Sunday           | last 3            |

Every snapshot is self-contained: restoring one does not depend on the others.

## Features

- **Database dumps without configuration**: running Postgres and MySQL/MariaDB containers are detected by image and dumped with `pg_dumpall` / `mariadb-dump`. Their raw data volumes are excluded, since copying live database files gives inconsistent backups.
- **Skip whole projects** (e.g. `staging_*`): no dumps, and their volumes are excluded even when the containers are stopped.
- **Exclusions** for logs, caches and local backup copies, configurable with restic patterns.
- **Size estimate** before uploading anything, using the same rules as the real backup.
- **Structured logs** in `/var/log/vps-backup/`, errors also in the systemd journal.
- **Monitoring** through an Uptime Kuma push monitor: `up` on success, `down` with the reason on failure.
- **Safe by default**: lock against overlapping runs, plaintext dumps always deleted, stale restic locks cleared, sampled integrity check after each full backup.
- **Any restic backend**: Google Drive or anything else through rclone, Backblaze B2, S3, SFTP.

## Requirements

- Debian or Ubuntu (tested on Debian 13)
- Docker, for database discovery and volumes
- Root access
- The installer adds `restic`, `rclone`, `curl`, `gzip`, `tar`, `util-linux`, `coreutils`, `logrotate`, `cron`

No Python, no jq.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/vps-backup/main/install.sh | sudo bash
```

Pin a release:

```bash
curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/vps-backup/main/install.sh | sudo bash -s -- --version 1.0.0
```

Installer options: `--version X.Y.Z` (default: latest release), `--ref BRANCH` (development), `--no-deps` (skip `apt-get`).

Layout after install:

```
/opt/vps-backup/                    code (replaced on update, previous version in /opt/vps-backup.old)
/etc/vps-backup/vps-backup.conf     configuration (never overwritten)
/etc/vps-backup/restic-password     repository password (created by 'vps-backup init')
/var/log/vps-backup/                logs (rotated weekly, 8 weeks kept)
/usr/local/bin/vps-backup           -> /opt/vps-backup/vps-backup
/etc/cron.d/vps-backup              schedule (managed by 'vps-backup schedule')
```

## First setup

1. **Configure**: `sudo nano /etc/vps-backup/vps-backup.conf` (see [Configuration](#configuration)).
2. **Repository backend**: for Google Drive see [below](#google-drive); for other backends set `RESTIC_REPOSITORY` and the related restic environment variables in the config.
3. **Initialize**:
   ```bash
   sudo vps-backup init
   ```
   Generates a random password in `/etc/vps-backup/restic-password` (if missing) and initializes the repository. **Store the password in a password manager immediately**: without it the backups cannot be decrypted, and the file disappears with the server.
4. **Check and test**:
   ```bash
   sudo vps-backup estimate
   sudo vps-backup run light
   sudo vps-backup run full
   sudo vps-backup status
   ```
5. **Test a restore** (the only proof a backup works):
   ```bash
   sudo vps-backup restic restore latest --tag full --target /tmp/restore-test --include /var/backups/vps-backup-dumps
   sudo ls -lh /tmp/restore-test/var/backups/vps-backup-dumps
   sudo rm -rf /tmp/restore-test
   ```
6. **Schedule**:
   ```bash
   sudo vps-backup schedule enable
   ```

## Usage

| Command                                         | Description                                                        |
|-------------------------------------------------|--------------------------------------------------------------------|
| `vps-backup run light\|full`                    | Run a backup                                                       |
| `vps-backup estimate`                           | Estimate sizes without uploading anything                          |
| `vps-backup status`                             | Schedule, latest snapshots per mode, recent vps-backup events      |
| `vps-backup init`                               | Create password (if missing) and initialize the repository         |
| `vps-backup schedule enable\|disable\|status`   | Manage the cron schedule from `LIGHT_SCHEDULE` / `FULL_SCHEDULE`   |
| `vps-backup restic <args>`                      | Run any restic command against the configured repository          |
| `vps-backup self-update [--version X.Y.Z]`      | Update vps-backup itself (config untouched)                        |
| `vps-backup version`                            | Print the installed version                                        |

All commands need root. Examples:

```bash
sudo vps-backup restic snapshots
sudo vps-backup restic stats --mode raw-data
sudo vps-backup restic ls latest --tag full /var/backups/vps-backup-dumps
```

## Configuration

`/etc/vps-backup/vps-backup.conf` is a bash file. Every value has a default; the example file documents them all.

| Setting                 | Default                          | Description                                                             |
|-------------------------|----------------------------------|-------------------------------------------------------------------------|
| `RESTIC_REPOSITORY`     | *(required)*                     | Restic repository, e.g. `rclone:gdrive:vps-backup`                      |
| `RESTIC_PASSWORD_FILE`  | `/etc/vps-backup/restic-password`| Repository password file                                                |
| `PUSH_URL`              | empty                            | Uptime Kuma push URL; empty disables notifications                      |
| `LOG_DIR`               | `/var/log/vps-backup`            | Log directory                                                           |
| `DUMP_DIR`              | `/var/backups/vps-backup-dumps`  | Temporary dump directory, deleted after each run                        |
| `VOLUMES_ROOT`          | `/var/lib/docker/volumes`        | Docker volumes directory                                                |
| `LIGHT_SCHEDULE`        | `0 3 * * 1-6`                    | Cron expression for light; empty disables it                            |
| `FULL_SCHEDULE`         | `0 3 * * 0`                      | Cron expression for full; empty disables it                             |
| `LIGHT_KEEP_LAST`       | `14`                             | Light snapshots kept                                                    |
| `FULL_KEEP_LAST`        | `3`                              | Full snapshots kept                                                     |
| `FULL_CHECK_SUBSET`     | `5%`                             | Data verified after each full; empty disables it                        |
| `CONFIG_PATHS`          | empty                            | Paths in both modes; missing ones are skipped with a warning            |
| `LIGHT_VOLUMES`         | empty                            | Docker volume names added to light (e.g. Uptime Kuma)                   |
| `SKIP_CONTAINERS`       | empty                            | Container name globs excluded entirely (e.g. `staging_*`)               |
| `POSTGRES_IMAGES`       | `postgres*`                      | Image globs dumped with `pg_dumpall` (uses `POSTGRES_USER`)             |
| `MYSQL_IMAGES`          | `mysql*` `mariadb*`              | Image globs dumped as root (`MARIADB_ROOT_PASSWORD` / `MYSQL_ROOT_PASSWORD`) |
| `FULL_EXCLUDE_PATTERNS` | empty                            | Extra restic exclude patterns for full                                  |

After changing a schedule, run `sudo vps-backup schedule enable` to regenerate the cron file.

## Google Drive

Restic reaches Google Drive through rclone. Use your own OAuth client: the shared rclone client is heavily rate-limited.

1. In [Google Cloud Console](https://console.cloud.google.com): create a project, enable the **Google Drive API**, configure the OAuth consent screen (External, app home page and privacy policy URLs are required), then **publish it to production**. In *Testing* mode the token expires every 7 days and scheduled backups stop working. Verification is not needed for personal use.
2. Create an **OAuth client ID** of type **Desktop app** and copy ID and secret (the secret may not be shown again).
3. On the server: `sudo rclone config` → new remote `gdrive`, type `drive`, your client ID and secret, scope **`drive.file`** (access only to files created by rclone), no shared drive, **auto config: No**.
4. rclone prints `rclone authorize "drive" "..."`. Run it on a machine with a browser. From WSL without installing rclone:
   ```bash
   docker run --rm -it --network host rclone/rclone authorize "drive" "<string>" --auth-no-open-browser
   ```
   Open the printed URL in your browser, accept the unverified-app warning (*Advanced → Go to app*), then paste the resulting token back on the server.
5. Check with `sudo rclone lsd gdrive:` and set `RESTIC_REPOSITORY="rclone:gdrive:vps-backup"`.

Deleted files go to the Drive trash for 30 days: a safety net if the repository is ever damaged from the server.

## Logging

```
/var/log/vps-backup/vps-backup.log   every run: timestamps, level, mode, restic and dump output
/var/log/vps-backup/cron.log         unexpected output from scheduled runs (usually empty)
journalctl -t vps-backup             errors only
```

Example:

```
2026-10-26 03:00:04 [INFO] [full] Dumped production_app-db-1 (postgres): 6.6MB
2026-10-26 03:04:51 [INFO] [full] Completed full backup in 4m 47s
```

## Disaster recovery

On a new server:

```bash
# 1. Install
curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/vps-backup/main/install.sh | sudo bash

# 2. Repository access: reconfigure rclone (or copy rclone.conf) and restore the password
sudo rclone config
sudo nano /etc/vps-backup/restic-password      # paste from your password manager
sudo chmod 600 /etc/vps-backup/restic-password
sudo nano /etc/vps-backup/vps-backup.conf      # at least RESTIC_REPOSITORY

# 3. Browse and restore
sudo vps-backup restic snapshots
sudo vps-backup restic restore latest --tag full --target /restore
```

The restored tree mirrors the original paths: `/restore/etc/...`, `/restore/var/www/...`, `/restore/var/lib/docker/volumes/...` and the dumps in `/restore/var/backups/vps-backup-dumps/`. Restore a dump into a fresh database container:

```bash
# Postgres
zcat app-db-1.sql.gz | docker exec -i <container> psql -U <user> -d postgres
# MySQL / MariaDB
zcat wp-db-1.sql.gz | docker exec -i <container> sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
```

The restored config contains `/etc/vps-backup/vps-backup.conf` and `/root/.config/rclone`, so the next server can be set up from the backup itself.

## Exit codes

| Code | Meaning                                                 |
|------|---------------------------------------------------------|
| `0`  | Success                                                 |
| `1`  | Usage error                                             |
| `2`  | Backup failed (already running, dump or restic failure) |
| `3`  | Configuration error (missing file, setting, command)    |

## Limitations

- Linux with GNU coreutils only.
- Database detection relies on official image naming and environment variables; other images need matching `*_IMAGES` globs and the same variables.
- Retention runs from the server, so whoever has root on it can also delete snapshots. For stronger protection use a backend with append-only credentials (e.g. Backblaze B2 keys without delete permission) and run `forget --prune` from another machine.
- Volumes other than databases are copied while containers run; files written during the backup may be captured mid-write.

## Uninstall

```bash
sudo vps-backup schedule disable
sudo rm -rf /opt/vps-backup /opt/vps-backup.old /usr/local/bin/vps-backup /etc/logrotate.d/vps-backup
# Optional, irreversible: configuration, password and logs
sudo rm -rf /etc/vps-backup /var/log/vps-backup
```

The remote repository is never touched.

## License

MIT
