#!/usr/bin/env bash
# "export" command: writes one snapshot to a single, human-named .tar.gz archive, on demand.
# The archive is NOT encrypted: it is meant to be downloaded and deleted from the server.
# shellcheck disable=SC2034,SC2154

# Temporary archive being written, removed by the EXIT trap unless completed
EXPORT_TMP=""

export_fail() {
  trap - ERR
  log ERROR "$*"
  # log only echoes to interactive terminals
  if [[ ! -t 1 ]]; then
    echo "Error: $*" >&2
  fi
  exit "$EXIT_BACKUP"
}

on_export_error() {
  local exit_code=$? line="$1"
  export_fail "Unexpected failure at line $line (exit code $exit_code)"
}

# Reads the JSON of 'restic snapshots --json' on stdin and prints
# "short_id time hostname tags" of the newest snapshot, nothing if there is none.
# No jq: restic writes compact JSON, each snapshot starts with "time" and ends with "short_id",
# and string values never contain a raw double quote.
newest_snapshot() {
  local token value time="" host="" tags="" epoch best="" best_epoch=-1
  while IFS= read -r token; do
    value="${token#*:}"
    value="${value#\"}"
    value="${value%\"}"
    case "$token" in
      '"time":'*)
        time="$value"
        host=""
        tags="[]"
        ;;
      '"hostname":'*) host="$value" ;;
      '"tags":'*)     tags="$value" ;;
      '"short_id":'*)
        if epoch=$(date -d "$time" +%s 2>/dev/null) && (( epoch > best_epoch )); then
          best_epoch="$epoch"
          best="$value $time ${host:--} $tags"
        fi
        ;;
    esac
  done < <(grep -oE '"(time|hostname|short_id)":"[^"]*"|"tags":\[[^]]*\]')

  if [[ -n "$best" ]]; then
    echo "$best"
  fi
  return 0
}

cmd_export() {
  local target="" output_dir=""
  local usage_text="usage: vps-backup export light|full|<snapshot-id> [--output DIR]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)
        if [[ -z "${2:-}" ]]; then
          die "$EXIT_USAGE" "--output requires a directory"
        fi
        output_dir="$2"
        shift 2
        ;;
      -*)
        die "$EXIT_USAGE" "$usage_text"
        ;;
      *)
        if [[ -n "$target" ]]; then
          die "$EXIT_USAGE" "$usage_text"
        fi
        target="$1"
        shift
        ;;
    esac
  done
  if [[ "$target" != "light" && "$target" != "full" && ! "$target" =~ ^[0-9a-f]{8,64}$ ]]; then
    die "$EXIT_USAGE" "$usage_text"
  fi

  require_root
  load_config
  require_commands restic gzip flock numfmt df
  require_password_file

  LOG_CONTEXT="export"
  output_dir="${output_dir:-$EXPORT_DIR}"

  # Never overlap a backup (or another export)
  if ! acquire_lock; then
    export_fail "Another backup or export is already running"
  fi

  trap 'on_export_error $LINENO' ERR
  # Never leave a partial archive behind
  trap 'if [[ -n "$EXPORT_TMP" ]]; then rm -f "$EXPORT_TMP"; fi' EXIT

  # --- Resolve the snapshot ---
  local snapshot_args json
  if [[ "$target" == "light" || "$target" == "full" ]]; then
    snapshot_args=(--latest 1 --tag "$target" --host "$BACKUP_SLUG")
  else
    snapshot_args=("$target")
  fi
  if ! json=$(restic snapshots --json "${snapshot_args[@]}"); then
    export_fail "Could not list snapshots (see the restic error above)"
  fi

  local short_id time host tags
  read -r short_id time host tags < <(newest_snapshot <<< "$json") || true
  if [[ -z "${short_id:-}" ]]; then
    if [[ "$target" == "light" || "$target" == "full" ]]; then
      export_fail "No $target snapshot found for host $BACKUP_SLUG"
    fi
    export_fail "Snapshot not found: $target"
  fi

  local mode="$target"
  if [[ "$target" != "light" && "$target" != "full" ]]; then
    case "$tags" in
      *'"light"'*) mode="light" ;;
      *'"full"'*)  mode="full" ;;
      *)           mode="snapshot" ;;
    esac
  fi

  # A snapshot exported by ID may come from another server sharing the repository
  local slug="$BACKUP_SLUG"
  if [[ "$host" =~ $SLUG_REGEX ]]; then
    slug="$host"
  fi

  local date name archive
  date=$(date -d "$time" +%Y-%m-%d)
  name="$mode-$date-$slug"

  if [[ ! -d "$output_dir" ]]; then
    mkdir -p "$output_dir"
    chmod 700 "$output_dir"
  fi
  archive="$output_dir/$name-backup.tar.gz"
  if [[ -e "$archive" ]]; then
    archive="$output_dir/$name-$short_id-backup.tar.gz"
  fi

  # --- Free space: the restore size is an upper bound for the compressed archive ---
  local stats restore_size available
  if ! stats=$(restic stats --mode restore-size --json "$short_id"); then
    export_fail "Could not compute the size of snapshot $short_id (see the restic error above)"
  fi
  restore_size=$(grep -oE '"total_size":[0-9]+' <<< "$stats" | head -n 1 | cut -d: -f2) || true
  if [[ -z "$restore_size" ]]; then
    export_fail "Could not read the size of snapshot $short_id from restic"
  fi
  available=$(df --output=avail -B1 "$output_dir" | tail -n 1 | tr -d ' ')
  if (( restore_size > available )); then
    export_fail "Not enough free space in $output_dir: snapshot restore size $(human_size "$restore_size"), available $(human_size "$available")." \
      "This check is conservative: the compressed archive is smaller than the restore size."
  fi

  log INFO "Exporting $mode snapshot $short_id of $slug ($time), restore size $(human_size "$restore_size")"

  # --- Write to a temporary file in the same directory, rename only on success ---
  EXPORT_TMP=$(mktemp "$output_dir/.$name.XXXXXX.tmp")
  if ! restic dump --archive tar "$short_id" / | gzip > "$EXPORT_TMP"; then
    export_fail "restic dump of snapshot $short_id failed"
  fi
  chmod 600 "$EXPORT_TMP"
  mv -f "$EXPORT_TMP" "$archive"
  EXPORT_TMP=""

  local size
  size=$(human_size "$(stat -c %s "$archive")")
  log INFO "Export completed: $archive ($size)"

  cat <<EOF
Exported snapshot $short_id ($mode, $time)

  File: $archive
  Size: $size

WARNING: this archive is NOT encrypted and contains secrets (.env files, database dumps).
Download it, then delete it from the server:

  scp root@$(hostname):$archive .
  sudo rm $archive
EOF
}
