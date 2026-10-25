# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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
