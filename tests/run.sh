#!/usr/bin/env bash
# Smoke tests for vps-backup, with fake docker and restic executables.
# Everything happens in a temporary directory: no real system path is touched.
#
#   tests/run.sh            run all tests
#   tests/run.sh NAME...    run only the named tests (e.g. test_export_full)
set -Euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VB="$REPO_DIR/vps-backup"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

BIN="$TEST_TMP/bin"
ROOT="$TEST_TMP/root"       # recreated for every test
OUT="$TEST_TMP/output"      # stdout and stderr of the last vps-backup call
FAILURES="$TEST_TMP/failures"
SKIPPED="$TEST_TMP/skipped"   # reason, when the current test cannot run here
STATUS=0                    # exit code of the last vps-backup call

# Environment seen by vps-backup and by the fakes
export TZ=UTC
export PATH="$BIN:$PATH"
export FAKE_ROOT="$ROOT"
export VPS_BACKUP_CONFIG="$ROOT/vps-backup.conf"
export VPS_BACKUP_LOCK_FILE="$ROOT/vps-backup.lock"
export VPS_BACKUP_CRON_FILE="$ROOT/cron.d/vps-backup"
export VPS_BACKUP_DEFAULT_EXPORT_DIR="$ROOT/default-exports"
export VPS_BACKUP_ALLOW_NON_ROOT=1
# Tests that simulate sudo set it themselves (also when the suite itself runs through sudo)
unset SUDO_USER

# --- Fake executables ----------------------------------------------------------

mkdir -p "$BIN"

# docker: running containers app-db-1 (postgres), wp-db-1 (mariadb), app-web-1 (nginx),
# staging_db-1 (postgres, skipped); stopped container staging_web-1 (skipped).
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
volumes="$FAKE_ROOT/volumes"
case "$1" in
  ps)
    if [[ "$2" == "-a" ]]; then
      printf '%s\n' app-db-1 wp-db-1 app-web-1 staging_db-1 staging_web-1
    else
      printf '%s\n' "app-db-1 postgres:16" "wp-db-1 mariadb:11" "app-web-1 nginx:1.27" \
        "staging_db-1 postgres:16"
    fi
    ;;
  inspect)
    case "${*: -1}" in
      app-db-1)      echo "$volumes/app_db_data/_data" ;;
      wp-db-1)       echo "$volumes/wp_db_data/_data" ;;
      app-web-1)     printf '%s\n' "$volumes/app_storage_data/_data" /srv/app/bind ;;
      staging_db-1)  echo "$volumes/staging_db_data/_data" ;;
      staging_web-1) echo "$volumes/staging_uploads/_data" ;;
      *)             echo "Error: No such object: ${*: -1}" >&2; exit 1 ;;
    esac
    ;;
  volume)
    name="${*: -1}"
    if [[ "$2" == "inspect" && -d "$volumes/$name" ]]; then
      echo "$volumes/$name/_data"
    else
      echo "Error: No such volume: $name" >&2
      exit 1
    fi
    ;;
  exec)
    echo "exec $2" >> "$FAKE_ROOT/docker-calls"
    if [[ "${FAKE_DOCKER_EMPTY_DUMP:-}" == "$2" ]]; then
      exit 0
    fi
    # Incompressible content, so the gzip dump is well above the 1 KiB sanity threshold
    echo "-- dump of $2"
    head -c 8192 /dev/urandom | base64
    ;;
  *)
    echo "fake docker: unsupported command: $*" >&2
    exit 1
    ;;
esac
EOF

# restic: records every call in $FAKE_ROOT/restic-calls (one line, arguments joined by spaces).
#   FAKE_RESTIC_FAIL=<subcommand>   that subcommand fails with a repository error
#   FAKE_RESTIC_NO_SNAPSHOTS=1      'snapshots --json' returns an empty list
#   FAKE_RESTIC_RESTORE_SIZE=N      total_size returned by 'stats --mode restore-size'
cat > "$BIN/restic" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ROOT/restic-calls"
command="$1"

if [[ "${FAKE_RESTIC_FAIL:-}" == "$command" ]]; then
  echo "Fatal: unable to open repository at $RESTIC_REPOSITORY: fake connection refused" >&2
  exit 1
fi

# Snapshots as written by restic 0.17 (compact JSON, nested summary, escaped quotes in paths)
summary='"summary":{"backup_start":"2026-10-18T12:00:01.1+02:00","backup_end":"2026-10-18T12:00:04.9+02:00","files_new":3,"total_bytes_processed":4096}'
full_old='{"time":"2026-10-11T12:00:05.123456789+02:00","tree":"aa11","paths":["/etc","/var/lib/docker/volumes"],"hostname":"test-vps","username":"root","excludes":["/var/lib/docker/volumes/*_logs"],"tags":["full"],"program_version":"restic 0.17.3",'"$summary"',"id":"1111111122222222333333334444444455555555666666667777777788888888","short_id":"11111111"}'
full_new='{"time":"2026-10-18T12:00:05.987654321+02:00","tree":"bb22","paths":["/etc","/srv/\"quoted\" dir","/var/lib/docker/volumes"],"hostname":"test-vps","username":"root","tags":["full"],"program_version":"restic 0.17.3",'"$summary"',"id":"abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01","short_id":"abcdef01"}'
light_other='{"time":"2026-10-20T09:30:00+02:00","tree":"cc33","paths":["/etc"],"hostname":"other-vps","username":"root","tags":["light"],"program_version":"restic 0.17.3",'"$summary"',"id":"cafe0123cafe0123cafe0123cafe0123cafe0123cafe0123cafe0123cafe0123","short_id":"cafe0123"}'

case "$command" in
  snapshots)
    if [[ " $* " != *" --json "* ]]; then
      echo "ID        Time                 Host      Tags   Paths"
      echo "abcdef01  2026-10-18 12:00:05  test-vps  full   /etc"
      exit 0
    fi
    if [[ -n "${FAKE_RESTIC_NO_SNAPSHOTS:-}" ]]; then
      echo "[]"
    elif [[ " $* " == *" --tag full "* ]]; then
      # Two path groups: --latest 1 returns one snapshot per group, newest not first
      echo "[$full_new,$full_old]"
    elif [[ " $* " == *" cafe0123 "* ]]; then
      echo "[$light_other]"
    elif [[ " $* " == *" --host test-vps "* && " $* " != *" --tag "* ]]; then
      echo "[$full_new]"
    else
      echo "[]"
    fi
    ;;
  stats)
    echo "{\"total_size\":${FAKE_RESTIC_RESTORE_SIZE:-1048576},\"total_file_count\":2,\"snapshots_count\":1}"
    ;;
  dump)
    content="$FAKE_ROOT/snapshot-content"
    mkdir -p "$content/etc"
    echo "APP_KEY=secret" > "$content/etc/app.env"
    tar -cf - -C "$content" .
    ;;
  backup)
    # Record which dumps existed while the snapshot was taken, and their modes
    if [[ -d "$FAKE_ROOT/dumps" ]]; then
      ls "$FAKE_ROOT/dumps" > "$FAKE_ROOT/dumps-at-backup"
    fi
    stat -c '%a %n' "$FAKE_ROOT/dumps"/* > "$FAKE_ROOT/dump-modes" 2>/dev/null
    echo "snapshot abcdef01 saved"
    ;;
  *)
    echo "fake restic: $command ok"
    ;;
esac
EOF

# hostname: fixed short name, used when BACKUP_SLUG is empty
cat > "$BIN/hostname" <<'EOF'
#!/usr/bin/env bash
echo "legacy-host"
EOF

# getent: only the test user vbtest exists, with its home inside the test root.
# Its uid and gid are FAKE_SUDO_UID (default: the current user, so chown works without root).
cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "passwd" && "$2" == "vbtest" ]]; then
  uid="${FAKE_SUDO_UID:-$(id -u)}"
  echo "vbtest:x:$uid:$uid:Test user:$FAKE_ROOT/home/vbtest:/bin/bash"
  exit 0
fi
exit 2
EOF

# logger: keep test errors out of the real journal
cat > "$BIN/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$BIN"/*

# --- Helpers -------------------------------------------------------------------

# Fresh root with config, volumes and configuration paths
setup() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT/etc/app" "$ROOT/www/site" "$ROOT/cron.d" \
    "$ROOT/volumes/app_db_data/_data" "$ROOT/volumes/wp_db_data/_data" \
    "$ROOT/volumes/app_storage_data/_data" "$ROOT/volumes/app_logs/_data" \
    "$ROOT/volumes/staging_db_data/_data" "$ROOT/volumes/staging_uploads/_data" \
    "$ROOT/volumes/kuma_data/_data"
  echo "DB_PASSWORD=secret" > "$ROOT/etc/app/.env"
  echo "password" > "$ROOT/restic-password"
  : > "$ROOT/restic-calls"

  cat > "$VPS_BACKUP_CONFIG" <<EOF
RESTIC_REPOSITORY="/fake/repository"
RESTIC_PASSWORD_FILE="$ROOT/restic-password"
BACKUP_SLUG="test-vps"
LOG_DIR="$ROOT/log"
DUMP_DIR="$ROOT/dumps"
VOLUMES_ROOT="$ROOT/volumes"
EXPORT_DIR="$ROOT/exports"
CONFIG_PATHS=("$ROOT/etc/app" "$ROOT/www" "$ROOT/missing-path")
LIGHT_VOLUMES=(kuma_data missing_volume)
SKIP_CONTAINERS=("staging_*")
FULL_EXCLUDE_PATTERNS=("\$VOLUMES_ROOT/*_logs")
EOF
}

# Appends lines to the test config
config() {
  printf '%s\n' "$@" >> "$VPS_BACKUP_CONFIG"
}

vb() {
  STATUS=0
  bash "$VB" "$@" > "$OUT" 2>&1 || STATUS=$?
}

fail() {
  echo "    $*" >> "$FAILURES"
}

skip() {
  echo "$*" > "$SKIPPED"
}

assert_status() {
  if [[ "$STATUS" != "$1" ]]; then
    fail "expected exit code $1, got $STATUS; output: $(head -c 400 "$OUT")"
  fi
}

# Usage: assert_contains FILE TEXT (fixed string)
assert_contains() {
  if ! grep -qF -- "$2" "$1" 2>/dev/null; then
    fail "$(basename "$1") does not contain: $2"
  fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    fail "$(basename "$1") unexpectedly contains: $2"
  fi
}

# Usage: assert_call PATTERN: some recorded restic call matches the extended regex
assert_call() {
  if ! grep -qE -- "$1" "$ROOT/restic-calls"; then
    fail "no restic call matching: $1"
  fi
}

assert_no_call() {
  if grep -qE -- "$1" "$ROOT/restic-calls"; then
    fail "unexpected restic call matching: $1"
  fi
}

restic_call() {
  grep -E -- "^$1( |$)" "$ROOT/restic-calls" || true
}

log_file() {
  echo "$ROOT/log/vps-backup.log"
}

# --- Tests: run ----------------------------------------------------------------

test_run_light() {
  vb run light
  assert_status 0
  local backup
  backup=$(restic_call backup)
  [[ "$backup" == *"--host test-vps --tag light "* ]] || fail "backup call lacks --host/--tag: $backup"
  [[ "$backup" == *" $ROOT/etc/app "* ]] || fail "config path not backed up: $backup"
  [[ "$backup" == *" $ROOT/www "* ]] || fail "config path not backed up: $backup"
  [[ "$backup" == *" $ROOT/volumes/kuma_data/_data"* ]] || fail "light volume not backed up: $backup"
  [[ "$backup" != *"missing"* ]] || fail "missing path passed to restic: $backup"
  [[ "$backup" != *"--exclude"* ]] || fail "light backup has exclusions: $backup"
  assert_call '^forget --compact --host test-vps --tag light --group-by tags --prune --keep-last 14$'
  assert_no_call '^check'
  assert_contains "$(log_file)" "[WARN] [light] Path not found, skipped: $ROOT/missing-path"
  assert_contains "$(log_file)" "[WARN] [light] Volume not found, skipped: missing_volume"
  assert_contains "$(log_file)" "Starting light backup of test-vps"
  assert_contains "$(log_file)" "Completed light backup"
}

test_run_full() {
  vb run full
  assert_status 0
  local backup
  backup=$(restic_call backup)
  [[ "$backup" == *"--host test-vps --tag full "* ]] || fail "backup call lacks --host/--tag: $backup"
  [[ "$backup" == *" $ROOT/dumps $ROOT/volumes" ]] || fail "volumes not backed up: $backup"
  # Raw database volumes, skipped containers (running and stopped) and configured patterns
  [[ "$backup" == *"--exclude $ROOT/volumes/app_db_data/_data "* ]] || fail "postgres volume not excluded"
  [[ "$backup" == *"--exclude $ROOT/volumes/wp_db_data/_data "* ]] || fail "mariadb volume not excluded"
  [[ "$backup" == *"--exclude $ROOT/volumes/staging_db_data/_data "* ]] || fail "running skipped container not excluded"
  [[ "$backup" == *"--exclude $ROOT/volumes/staging_uploads/_data "* ]] || fail "stopped skipped container not excluded"
  [[ "$backup" == *"--exclude $ROOT/volumes/*_logs "* ]] || fail "configured pattern not excluded"
  [[ "$backup" != *"app_storage_data"* ]] || fail "regular volume excluded: $backup"
  # Dumps existed during the backup, only for non-skipped databases, and are gone afterwards
  assert_contains "$ROOT/dumps-at-backup" "app-db-1.sql.gz"
  assert_contains "$ROOT/dumps-at-backup" "wp-db-1.sql.gz"
  assert_not_contains "$ROOT/dumps-at-backup" "staging"
  assert_not_contains "$ROOT/docker-calls" "staging"
  # Dumps readable by root only, whatever the caller's umask
  [[ -s "$ROOT/dump-modes" ]] || fail "dump modes not recorded"
  if grep -qv '^600 ' "$ROOT/dump-modes" 2>/dev/null; then
    fail "dump files not created with mode 600: $(tr '\n' ' ' < "$ROOT/dump-modes")"
  fi
  [[ ! -e "$ROOT/dumps" ]] || fail "dump directory left on disk"
  assert_call '^forget --compact --host test-vps --tag full --group-by tags --prune --keep-last 3$'
  assert_call '^check --read-data-subset=5%$'
  assert_contains "$(log_file)" "Dumped app-db-1 (postgres)"
  assert_contains "$(log_file)" "Dumped wp-db-1 (mysql)"
}

test_run_default_slug_is_short_hostname() {
  # A 1.0.x config has no BACKUP_SLUG
  sed -i '/^BACKUP_SLUG=/d' "$VPS_BACKUP_CONFIG"
  vb run light
  assert_status 0
  assert_call '^backup --host legacy-host --tag light '
  assert_call '^forget --compact --host legacy-host --tag light '
}

test_run_restic_failure() {
  export FAKE_RESTIC_FAIL=backup
  vb run full
  assert_status 2
  assert_contains "$(log_file)" "[ERROR] [full]"
  assert_contains "$(log_file)" "fake connection refused"
  assert_no_call '^forget'
  [[ ! -e "$ROOT/dumps" ]] || fail "dump directory left on disk after failure"
}

test_run_dump_too_small() {
  export FAKE_DOCKER_EMPTY_DUMP=wp-db-1
  vb run full
  assert_status 2
  assert_contains "$(log_file)" "[ERROR] [full] dump of wp-db-1 is suspiciously small"
  assert_no_call '^backup'
  [[ ! -e "$ROOT/dumps" ]] || fail "dump directory left on disk after failure"
}

test_run_lock_held() {
  # Another run holds the lock and is writing its dumps: they must not be touched
  mkdir -p "$ROOT/dumps"
  echo "in progress" > "$ROOT/dumps/app-db-1.sql.gz"
  exec 8> "$VPS_BACKUP_LOCK_FILE"
  flock -n 8 || fail "could not take the lock in the test"
  vb run full
  exec 8>&-
  assert_status 2
  assert_contains "$(log_file)" "[ERROR] [full] Another backup or export is already running"
  assert_no_call '^(unlock|backup)'
  [[ -f "$ROOT/dumps/app-db-1.sql.gz" ]] || fail "dumps of the running backup were removed"
}

# --- Tests: configuration ------------------------------------------------------

test_config_missing_file() {
  rm -f "$VPS_BACKUP_CONFIG"
  vb run light
  assert_status 3
  assert_contains "$OUT" "config file not found"
}

test_config_missing_repository() {
  config 'RESTIC_REPOSITORY=""'
  vb run light
  assert_status 3
  assert_contains "$OUT" "RESTIC_REPOSITORY is not set"
  assert_no_call '.'
}

test_config_invalid_slug() {
  local slug
  for slug in "Prod_Server" "web.example.com" "$(printf 'a%.0s' {1..64})"; do
    setup
    config "BACKUP_SLUG=\"$slug\""
    vb run light
    assert_status 3
    assert_contains "$OUT" "invalid BACKUP_SLUG"
    assert_no_call '.'
  done
}

# --- Tests: export -------------------------------------------------------------

test_export_full() {
  vb export full
  assert_status 0
  assert_call '^snapshots --json --latest 1 --tag full --host test-vps$'
  assert_call '^stats --mode restore-size --json abcdef01$'
  assert_call '^dump --archive tar abcdef01 /$'

  # Newest snapshot, its own date (not today's), mode 600, directory created with mode 700
  local archive="$ROOT/exports/full-2026-10-18-test-vps-backup.tar.gz"
  [[ -f "$archive" ]] || fail "archive not created: $(ls "$ROOT/exports" 2>&1)"
  [[ "$(stat -c %a "$archive" 2>/dev/null)" == "600" ]] || fail "archive mode is not 600"
  [[ "$(stat -c %a "$ROOT/exports" 2>/dev/null)" == "700" ]] || fail "export directory mode is not 700"
  tar -tzf "$archive" 2>/dev/null | grep -q 'etc/app.env' || fail "archive does not contain the snapshot"
  [[ -z "$(find "$ROOT/exports" -name "*.tmp" 2>/dev/null)" ]] || fail "temporary file left behind"
  assert_contains "$OUT" "NOT encrypted"
  assert_contains "$OUT" "scp <ssh-host>:$archive ."
  assert_contains "$OUT" "  sudo rm $archive"
  assert_contains "$(log_file)" "[INFO] [export] Export completed: $archive"

  # Same name already taken: the short ID is appended
  vb export full
  assert_status 0
  [[ -f "$ROOT/exports/full-2026-10-18-test-vps-abcdef01-backup.tar.gz" ]] \
    || fail "second export not suffixed with the short ID: $(ls "$ROOT/exports")"
}

test_export_by_id() {
  vb export cafe0123 --output "$ROOT/custom/out"
  assert_status 0
  assert_call '^snapshots --json cafe0123$'
  # Mode from the tags, host of the snapshot (it comes from another server)
  [[ -f "$ROOT/custom/out/light-2026-10-20-other-vps-backup.tar.gz" ]] \
    || fail "unexpected archive name: $(ls -R "$ROOT/custom" 2>&1)"
  [[ "$(stat -c %a "$ROOT/custom/out" 2>/dev/null)" == "700" ]] || fail "output directory mode is not 700"
}

test_export_sudo_user() {
  if [[ $EUID -ne 0 ]]; then
    skip "giving files to another user needs root (run: sudo bash tests/run.sh test_export_sudo_user)"
    return
  fi
  export SUDO_USER=vbtest FAKE_SUDO_UID=4242
  sed -i '/^EXPORT_DIR=/d' "$VPS_BACKUP_CONFIG"
  mkdir -p "$ROOT/home/vbtest"
  vb export full
  assert_status 0

  # Automatic directory in the sudo user's home, directory and archive owned by them
  local dir="$ROOT/home/vbtest/vps-backup-exports"
  local name="full-2026-10-18-test-vps-backup.tar.gz"
  [[ -f "$dir/$name" ]] || fail "archive not in the sudo user's home: $(ls -R "$ROOT/home" 2>&1)"
  [[ "$(stat -c '%u:%g %a' "$dir/$name" 2>/dev/null)" == "4242:4242 600" ]] \
    || fail "archive owner/mode: $(stat -c '%u:%g %a' "$dir/$name" 2>&1)"
  [[ "$(stat -c '%u:%g %a' "$dir" 2>/dev/null)" == "4242:4242 700" ]] \
    || fail "directory owner/mode: $(stat -c '%u:%g %a' "$dir" 2>&1)"
  [[ -z "$(find "$dir" -name "*.tmp" 2>/dev/null)" ]] || fail "temporary file left behind"
  assert_contains "$OUT" "scp <ssh-host>:~/vps-backup-exports/$name ."
  assert_contains "$OUT" "  rm ~/vps-backup-exports/$name"
  assert_not_contains "$OUT" "root@"
  assert_not_contains "$OUT" "sudo rm"
  assert_contains "$OUT" "NOT encrypted"

  # An explicit directory that already exists keeps its owner; only the archive is handed over
  mkdir -p "$ROOT/shared"
  vb export full --output "$ROOT/shared"
  assert_status 0
  [[ "$(stat -c %u "$ROOT/shared/$name" 2>/dev/null)" == "4242" ]] || fail "archive in --output not owned by the sudo user"
  [[ "$(stat -c %u "$ROOT/shared")" == "0" ]] || fail "existing --output directory changed owner"
  assert_contains "$OUT" "  sudo rm $ROOT/shared/$name"
}

test_export_default_without_sudo_user() {
  # No sudo user, root, or a user unknown to getent: the system default directory
  local sudo_user dir="$ROOT/default-exports"
  for sudo_user in "" root ghost; do
    setup
    sed -i '/^EXPORT_DIR=/d' "$VPS_BACKUP_CONFIG"
    if [[ -n "$sudo_user" ]]; then
      export SUDO_USER="$sudo_user"
    else
      unset SUDO_USER
    fi
    vb export full
    assert_status 0
    [[ -f "$dir/full-2026-10-18-test-vps-backup.tar.gz" ]] \
      || fail "SUDO_USER='$sudo_user': archive not in the default directory: $(ls -A "$dir" 2>&1)"
    [[ "$(stat -c %a "$dir" 2>/dev/null)" == "700" ]] || fail "default directory mode is not 700"
    [[ ! -e "$ROOT/home" ]] || fail "SUDO_USER='$sudo_user': a home directory was used"
    assert_contains "$OUT" "scp <ssh-host>:$dir/full-2026-10-18-test-vps-backup.tar.gz ."
    assert_contains "$OUT" "  sudo rm $dir/"
  done
}

test_export_explicit_dir_wins() {
  # vbtest has the current uid, so this runs without root too
  export SUDO_USER=vbtest
  mkdir -p "$ROOT/home/vbtest"
  local name="full-2026-10-18-test-vps-backup.tar.gz"

  # EXPORT_DIR from the config (set by setup) beats the sudo user's home
  vb export full
  assert_status 0
  [[ -f "$ROOT/exports/$name" ]] || fail "EXPORT_DIR not used: $(ls -A "$ROOT/exports" 2>&1)"
  [[ "$(stat -c %a "$ROOT/exports" 2>/dev/null)" == "700" ]] || fail "export directory mode is not 700"
  assert_contains "$OUT" "scp <ssh-host>:$ROOT/exports/$name ."

  # --output beats EXPORT_DIR
  vb export full --output "$ROOT/out"
  assert_status 0
  [[ -f "$ROOT/out/$name" ]] || fail "--output not used: $(ls -A "$ROOT/out" 2>&1)"
  [[ ! -e "$ROOT/home/vbtest/vps-backup-exports" ]] || fail "automatic directory created despite an explicit one"
  [[ ! -e "$ROOT/default-exports" ]] || fail "default directory created despite an explicit one"
}

test_export_insufficient_space() {
  export FAKE_RESTIC_RESTORE_SIZE=999999999999999999
  vb export full
  assert_status 2
  assert_contains "$OUT" "Not enough free space"
  assert_contains "$OUT" "conservative"
  assert_contains "$(log_file)" "[ERROR] [export] Not enough free space"
  assert_no_call '^dump'
  [[ -z "$(ls -A "$ROOT/exports" 2>/dev/null)" ]] || fail "files left in the export directory"
}

test_export_dump_failure() {
  export FAKE_RESTIC_FAIL=dump
  vb export full
  assert_status 2
  assert_contains "$(log_file)" "[ERROR] [export] restic dump of snapshot abcdef01 failed"
  [[ -z "$(ls -A "$ROOT/exports" 2>/dev/null)" ]] || fail "temporary file left behind: $(ls -A "$ROOT/exports" 2>/dev/null)"
}

test_export_no_snapshot() {
  export FAKE_RESTIC_NO_SNAPSHOTS=1
  vb export light
  assert_status 2
  assert_contains "$OUT" "No light snapshot found for host test-vps"
}

test_export_lock_held() {
  exec 8> "$VPS_BACKUP_LOCK_FILE"
  flock -n 8 || fail "could not take the lock in the test"
  vb export full
  exec 8>&-
  assert_status 2
  assert_contains "$OUT" "already running"
  assert_no_call '.'
}

test_export_usage() {
  vb export
  assert_status 1
  vb export "--host x"
  assert_status 1
  vb export full --output
  assert_status 1
}

# --- Tests: status and schedule ------------------------------------------------

test_status() {
  vb status
  assert_status 0
  assert_contains "$OUT" "(slug: test-vps)"
  assert_contains "$OUT" "abcdef01  2026-10-18"
  assert_call '^snapshots --compact --host test-vps --group-by tags --latest 3$'
}

test_status_no_snapshots() {
  export FAKE_RESTIC_NO_SNAPSHOTS=1
  vb status
  assert_status 0
  assert_call '^snapshots --json --latest 1 --host test-vps$'
  assert_contains "$OUT" "  No snapshots yet for test-vps"
  assert_no_call '^snapshots --compact'
}

test_status_restic_error() {
  export FAKE_RESTIC_FAIL=snapshots
  vb status
  assert_status 0
  assert_contains "$OUT" "Repository error:"
  assert_contains "$OUT" "    Fatal: unable to open repository at /fake/repository: fake connection refused"
}

test_schedule() {
  vb schedule enable
  assert_status 0
  assert_contains "$VPS_BACKUP_CRON_FILE" "0 3 * * 1-6 root /usr/local/bin/vps-backup run light"
  assert_contains "$VPS_BACKUP_CRON_FILE" "0 3 * * 0 root /usr/local/bin/vps-backup run full"
  [[ "$(stat -c %a "$VPS_BACKUP_CRON_FILE" 2>/dev/null)" == "600" ]] || fail "cron file mode is not 600"
  vb schedule disable
  assert_status 0
  [[ ! -e "$VPS_BACKUP_CRON_FILE" ]] || fail "cron file not removed"
}

# --- Runner --------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
  tests=("$@")
else
  mapfile -t tests < <(declare -F | sed -n "s/^declare -f \\(test_.*\\)/\\1/p")
fi

passed=0
failed=0
skipped=0
for test in "${tests[@]}"; do
  setup
  : > "$FAILURES"
  rm -f "$SKIPPED"
  # Subshell: exported FAKE_* variables and open descriptors do not leak between tests
  ( "$test" )
  if [[ -s "$SKIPPED" ]]; then
    echo "SKIP  $test: $(cat "$SKIPPED")"
    skipped=$((skipped + 1))
  elif [[ -s "$FAILURES" ]]; then
    echo "FAIL  $test"
    cat "$FAILURES"
    failed=$((failed + 1))
  else
    echo "PASS  $test"
    passed=$((passed + 1))
  fi
done

echo
echo "$passed passed, $failed failed, $skipped skipped"
if (( failed > 0 )); then
  exit 1
fi
