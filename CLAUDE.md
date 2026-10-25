# CLAUDE.md

Guidance for working on this repository.

## What this is

`vps-backup` is a pure-bash wrapper around restic for backing up a single Docker host:
configuration (light) nightly, configuration + database dumps + Docker volumes (full) weekly.
It is installed with one command and must be reproducible on a fresh Debian server.

## Layout

```
vps-backup                 entrypoint: sources lib/*, dispatches commands
lib/common.sh              config loading, logging, notifications, DB discovery, exclusions
lib/backup.sh              "run" command
lib/estimate.sh            "estimate" command
lib/export.sh              "export" command
lib/commands.sh            init, status, schedule, restic, self-update
install.sh                 installer and updater (also used by self-update)
templates/logrotate        installed to /etc/logrotate.d/vps-backup
vps-backup.conf.example    documented configuration, copied once to /etc/vps-backup
tests/run.sh               smoke tests with fake docker and restic (not installed)
```

## Design rules

- **Code and config are separate.** Code lives in `/opt/vps-backup` and is replaced on every update.
  `/etc/vps-backup/vps-backup.conf` is created once and never overwritten. New settings must have a
  default in `load_config()` so old config files keep working.
- **One source of truth for what is backed up.** `estimate` and `run` share `build_excludes`,
  `list_databases` and the config. Never duplicate inclusion or exclusion logic.
- **Never leave plaintext dumps on disk.** `DUMP_DIR` is removed by an EXIT trap, also on failure.
- **Fail loudly.** Every failure is logged as ERROR, sent to the journal and to the push monitor.
  A missing optional path or volume is a WARN, not a failure.
- **Retention is grouped by tag** (`--group-by tags`), so changing `CONFIG_PATHS` does not leave
  orphaned snapshot groups that are never pruned.
- **No new dependencies** beyond what Debian ships: no Python, no jq.

## Conventions

- Bash with `set -Eeuo pipefail` in entrypoints; library files are sourced, not executed.
- Identifiers, comments, logs and docs in English.
- Functions that may legitimately produce no output end with `return 0`, so `set -e`
  does not abort on a false final test.
- Must pass `bash -n` and `shellcheck -x vps-backup install.sh lib/*.sh tests/run.sh` (CI enforces it).

## Testing

`tests/run.sh` (pure bash, no framework) runs the commands against fake `docker`, `restic`,
`hostname` and `logger` executables placed first in `PATH`, inside a temporary directory.
Run `bash tests/run.sh`, or `bash tests/run.sh test_export_full ...` for single tests.
It needs neither root nor Docker. CI runs it after ShellCheck.

- The fake `restic` records every call in `$FAKE_ROOT/restic-calls`; tests assert on those lines.
  `FAKE_RESTIC_FAIL=<subcommand>`, `FAKE_RESTIC_NO_SNAPSHOTS=1` and `FAKE_RESTIC_RESTORE_SIZE=N`
  change its behaviour; `FAKE_DOCKER_EMPTY_DUMP=<container>` makes that dump empty.
- Tests must never touch real system paths. Hard-coded system paths are overridable through
  environment variables that default to the production value. Any new one must follow the
  same pattern and be listed here:

  | Variable                    | Default                                     |
  |-----------------------------|---------------------------------------------|
  | `VPS_BACKUP_CONFIG`         | `/etc/vps-backup/vps-backup.conf`           |
  | `VPS_BACKUP_LOCK_FILE`      | `/run/lock/vps-backup.lock`                 |
  | `VPS_BACKUP_CRON_FILE`      | `/etc/cron.d/vps-backup`                    |
  | `VPS_BACKUP_DEFAULT_EXPORT_DIR` | `/var/backups/vps-backup-exports`       |
  | `VPS_BACKUP_ALLOW_NON_ROOT` | unset; `1` skips the root check (tests only) |

- New behaviour comes with a test.

## Releasing

1. Update `VERSION` and `CHANGELOG.md`.
2. Commit, then tag `vX.Y.Z` matching `VERSION` and push the tag.
3. The release workflow checks the tag against `VERSION`, lints and creates the GitHub release.

Exit codes: 0 success, 1 usage, 2 backup failure, 3 configuration error.
