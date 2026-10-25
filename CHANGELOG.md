# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-25

### Added
- `BACKUP_SLUG`: user-defined host name stored in every snapshot (default: `hostname -s`).
  Several servers can share one repository.
- `export light|full|<snapshot-id> [--output DIR]`: writes a snapshot to a single
  `<mode>-<date>-<slug>-backup.tar.gz` archive in `EXPORT_DIR`, after checking free space.
- Smoke test suite (`tests/run.sh`) with fake `docker` and `restic`, run in CI.

### Changed
- `status` shows the actual restic error when the repository cannot be read, and the slug.
- Retention is scoped by host (`--host <slug>`), so servers sharing a repository never prune
  each other's snapshots.

## [1.0.1] - 2026-10-25

### Changed
- Retention output is now compact, keeping the log readable.
- `status` shows only vps-backup events; restic output remains in the log file.

## [1.0.0] - 2026-10-25

### Added
- `run light|full`: encrypted restic backups of configuration (light) and of
  configuration, database dumps and Docker volumes (full).
- Automatic discovery and dump of running Postgres and MySQL/MariaDB containers;
  raw database volumes are excluded in favour of the dumps.
- `SKIP_CONTAINERS` to exclude whole projects (e.g. staging), including stopped ones.
- Retention per mode grouped by tag, with a sampled integrity check after each full.
- `estimate`, `status`, `init`, `schedule`, `restic` and `self-update` commands.
- Structured logging to `/var/log/vps-backup`, errors to the journal, Uptime Kuma push notifications.
- One-command installer with atomic updates; configuration is never overwritten.
