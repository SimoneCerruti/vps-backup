#!/usr/bin/env bash
# "run" command: light and full backups.
# shellcheck disable=SC2034,SC2154

backup_fail() {
  trap - ERR
  log ERROR "$*"
  notify down "$BACKUP_MODE backup: $*"
  exit "$EXIT_BACKUP"
}

on_backup_error() {
  local exit_code=$? line="$1"
  trap - ERR
  log ERROR "Unexpected failure at line $line (exit code $exit_code)"
  notify down "$BACKUP_MODE backup failed (line $line)"
  exit "$EXIT_BACKUP"
}

cmd_run() {
  local mode="${1:-}"
  if [[ "$mode" != "light" && "$mode" != "full" ]]; then
    die "$EXIT_USAGE" "usage: vps-backup run light|full"
  fi

  require_root
  load_config
  require_commands restic docker curl gzip flock numfmt
  if [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then
    die "$EXIT_CONFIG" "password file missing: $RESTIC_PASSWORD_FILE (run 'vps-backup init')"
  fi

  BACKUP_MODE="$mode"
  LOG_CONTEXT="$mode"

  # Prevent overlapping runs
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log ERROR "Another backup is already running"
    exit "$EXIT_BACKUP"
  fi

  trap 'on_backup_error $LINENO' ERR
  # Never leave plaintext database dumps on disk, even on failure
  trap 'rm -rf "$DUMP_DIR"' EXIT

  local started_at
  started_at=$(date +%s)
  log INFO "Starting $mode backup (vps-backup $(vps_backup_version))"

  local paths=("${CONFIG_PATHS[@]}")
  local restic_args=(--tag "$mode")
  local volume volume_path name engine dump_file size exclude

  if [[ "$mode" == "light" ]]; then
    for volume in "${LIGHT_VOLUMES[@]}"; do
      if volume_path=$(docker volume inspect -f '{{.Mountpoint}}' "$volume" 2>/dev/null); then
        paths+=("$volume_path")
        log INFO "Including volume $volume"
      else
        log WARN "Volume not found, skipped: $volume"
      fi
    done
  else
    mkdir -p "$DUMP_DIR"
    chmod 700 "$DUMP_DIR"

    while read -r name engine; do
      dump_file="$DUMP_DIR/$name.sql.gz"
      dump_database "$name" "$engine" > "$dump_file" 2>> "$LOG_FILE"

      size=$(stat -c %s "$dump_file")
      if (( size < 1024 )); then
        backup_fail "dump of $name is suspiciously small ($size bytes): check database credentials"
      fi
      log INFO "Dumped $name ($engine): $(numfmt --to=iec --suffix=B "$size")"
    done < <(list_databases)

    build_excludes
    for exclude in "${EXCLUDES[@]}"; do
      restic_args+=(--exclude "$exclude")
    done
    log INFO "Applied ${#EXCLUDES[@]} exclusions"

    paths+=("$DUMP_DIR" "$VOLUMES_ROOT")
  fi

  # Configured paths that do not exist on this server are skipped, not fatal
  local existing_paths=() path
  for path in "${paths[@]}"; do
    if [[ -e "$path" ]]; then
      existing_paths+=("$path")
    else
      log WARN "Path not found, skipped: $path"
    fi
  done

  # Remove stale locks left by interrupted runs (active locks are kept)
  run_logged restic unlock

  log INFO "Uploading snapshot"
  run_logged restic backup "${restic_args[@]}" "${existing_paths[@]}"

  # Retention is grouped by tag, so changing the configured paths does not orphan old snapshots
  log INFO "Applying retention"
  if [[ "$mode" == "light" ]]; then
    run_logged restic forget --tag light --group-by tags --prune --keep-last "$LIGHT_KEEP_LAST"
  else
    run_logged restic forget --tag full --group-by tags --prune --keep-last "$FULL_KEEP_LAST"
    if [[ -n "${FULL_CHECK_SUBSET:-}" ]]; then
      log INFO "Verifying $FULL_CHECK_SUBSET of the stored data"
      run_logged restic check --read-data-subset="$FULL_CHECK_SUBSET"
    fi
  fi

  local elapsed duration
  elapsed=$(( $(date +%s) - started_at ))
  duration="$((elapsed / 60))m $((elapsed % 60))s"
  log INFO "Completed $mode backup in $duration"
  notify up "$mode OK in $duration"
}
