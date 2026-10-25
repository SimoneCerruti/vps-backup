#!/usr/bin/env bash
# Shared functions for vps-backup: config loading, logging, notifications,
# database discovery and exclusions. Sourced by the vps-backup entrypoint.
# shellcheck disable=SC2034,SC2154

EXIT_USAGE=1
EXIT_BACKUP=2
EXIT_CONFIG=3

DEFAULT_REPO_SLUG="SimoneCerruti/vps-backup"
VPS_BACKUP_CONFIG="${VPS_BACKUP_CONFIG:-/etc/vps-backup/vps-backup.conf}"
CRON_FILE="/etc/cron.d/vps-backup"
LOCK_FILE="/run/lock/vps-backup.lock"

# Usage: die EXIT_CODE message...
die() {
  local code="$1"
  shift
  echo "Error: $*" >&2
  exit "$code"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "$EXIT_USAGE" "this command must be run as root (use sudo)"
  fi
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      die "$EXIT_CONFIG" "required command not found: $cmd"
    fi
  done
}

vps_backup_version() {
  cat "$VPS_BACKUP_HOME/VERSION" 2>/dev/null || echo "unknown"
}

load_config() {
  # Defaults: every value can be overridden by the config file
  RESTIC_REPOSITORY=""
  RESTIC_PASSWORD_FILE="/etc/vps-backup/restic-password"
  PUSH_URL=""
  LOG_DIR="/var/log/vps-backup"
  DUMP_DIR="/var/backups/vps-backup-dumps"
  VOLUMES_ROOT="/var/lib/docker/volumes"
  LIGHT_KEEP_LAST=14
  FULL_KEEP_LAST=3
  FULL_CHECK_SUBSET="5%"
  LIGHT_SCHEDULE="0 3 * * 1-6"
  FULL_SCHEDULE="0 3 * * 0"
  CONFIG_PATHS=()
  LIGHT_VOLUMES=()
  SKIP_CONTAINERS=()
  POSTGRES_IMAGES=("postgres*")
  MYSQL_IMAGES=("mysql*" "mariadb*")
  FULL_EXCLUDE_PATTERNS=()

  if [[ ! -r "$VPS_BACKUP_CONFIG" ]]; then
    die "$EXIT_CONFIG" "config file not found or not readable: $VPS_BACKUP_CONFIG"
  fi
  # shellcheck source=/dev/null
  source "$VPS_BACKUP_CONFIG"

  if [[ -z "$RESTIC_REPOSITORY" ]]; then
    die "$EXIT_CONFIG" "RESTIC_REPOSITORY is not set in $VPS_BACKUP_CONFIG"
  fi
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/vps-backup.log"
}

# Usage: log LEVEL message...
# Writes to the log file, to the terminal when interactive, and errors to the journal.
log() {
  local level="$1"
  shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] [${LOG_CONTEXT:-main}] $*"

  echo "$line" >> "$LOG_FILE"
  if [[ -t 1 ]]; then
    echo "$line"
  fi
  if [[ "$level" == "ERROR" ]]; then
    logger -t vps-backup -p user.err "$*" 2>/dev/null || true
  fi
}

# Runs a command and sends every line of its output to the log
run_logged() {
  "$@" 2>&1 | while IFS= read -r line; do
    log INFO "  $line"
  done
}

# Sends a heartbeat to an Uptime Kuma push monitor (disabled when PUSH_URL is empty)
notify() {
  if [[ -z "${PUSH_URL:-}" ]]; then
    return 0
  fi
  curl -fsS --max-time 15 --get \
    --data-urlencode "status=$1" --data-urlencode "msg=$2" \
    "$PUSH_URL" >/dev/null || log WARN "Could not reach the push URL"
}

# Usage: matches_any VALUE PATTERN... (glob matching)
matches_any() {
  local value="$1"
  shift
  local pattern
  for pattern in "$@"; do
    # shellcheck disable=SC2053  # unquoted on purpose: glob matching
    if [[ "$value" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

is_skipped_container() {
  matches_any "$1" "${SKIP_CONTAINERS[@]}"
}

# Prints "postgres" or "mysql" for supported database images, nothing otherwise
db_engine_of() {
  local image="$1"
  if matches_any "$image" "${POSTGRES_IMAGES[@]}"; then
    echo "postgres"
  elif matches_any "$image" "${MYSQL_IMAGES[@]}"; then
    echo "mysql"
  fi
  return 0
}

# Prints "name engine" for every running, non-skipped database container
list_databases() {
  local name image engine
  while read -r name image; do
    if is_skipped_container "$name"; then
      continue
    fi
    engine=$(db_engine_of "$image")
    if [[ -n "$engine" ]]; then
      echo "$name $engine"
    fi
  done < <(docker ps --format '{{.Names}} {{.Image}}')
  return 0
}

# Writes a gzip-compressed dump of all databases in the container to stdout
dump_database() {
  local name="$1" engine="$2"
  case "$engine" in
    postgres)
      # shellcheck disable=SC2016  # variables are expanded inside the container
      docker exec "$name" sh -c 'pg_dumpall -U "$POSTGRES_USER"'
      ;;
    mysql)
      # shellcheck disable=SC2016  # variables are expanded inside the container
      docker exec "$name" sh -c '
        dump=$(command -v mariadb-dump || command -v mysqldump)
        MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" "$dump" --all-databases --single-transaction -uroot
      '
      ;;
  esac | gzip
}

# Prints the mount sources of a container that live inside VOLUMES_ROOT
volume_mounts_of() {
  local source
  while read -r source; do
    if [[ "$source" == "$VOLUMES_ROOT"/* ]]; then
      echo "$source"
    fi
  done < <(docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$1")
  return 0
}

# Fills the global EXCLUDES array for the full backup:
# configured patterns + raw volumes of dumped databases + volumes of skipped containers
build_excludes() {
  EXCLUDES=("${FULL_EXCLUDE_PATTERNS[@]}")
  local name engine source

  # Raw database files are inconsistent while the database runs: the dump replaces them
  while read -r name engine; do
    while read -r source; do
      EXCLUDES+=("$source")
    done < <(volume_mounts_of "$name")
  done < <(list_databases)

  # Skipped containers, including stopped ones
  while read -r name; do
    if is_skipped_container "$name"; then
      while read -r source; do
        EXCLUDES+=("$source")
      done < <(volume_mounts_of "$name")
    fi
  done < <(docker ps -a --format '{{.Names}}')

  return 0
}
