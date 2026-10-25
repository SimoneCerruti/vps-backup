#!/usr/bin/env bash
# Setup and maintenance commands: init, status, schedule, restic, self-update.
# shellcheck disable=SC2154

cmd_init() {
  require_root
  load_config
  require_commands restic

  if [[ "$RESTIC_REPOSITORY" == rclone:* ]]; then
    require_commands rclone
    local remote="${RESTIC_REPOSITORY#rclone:}"
    remote="${remote%%:*}"
    if ! rclone lsd "$remote:" >/dev/null 2>&1; then
      die "$EXIT_CONFIG" "rclone remote '$remote' is not reachable: configure it with 'sudo rclone config'"
    fi
  fi

  if [[ -s "$RESTIC_PASSWORD_FILE" ]]; then
    echo "==> Using existing password file: $RESTIC_PASSWORD_FILE"
  else
    mkdir -p "$(dirname "$RESTIC_PASSWORD_FILE")"
    (
      umask 077
      head -c 32 /dev/urandom | base64 > "$RESTIC_PASSWORD_FILE"
    )
    echo "==> Generated repository password: $RESTIC_PASSWORD_FILE"
    echo
    echo "    $(cat "$RESTIC_PASSWORD_FILE")"
    echo
    echo "    SAVE IT IN YOUR PASSWORD MANAGER NOW."
    echo "    Without it the backups cannot be decrypted, and the file is lost with the server."
    echo
  fi

  if restic cat config >/dev/null 2>&1; then
    echo "==> Repository already initialized: $RESTIC_REPOSITORY"
  else
    echo "==> Initializing repository: $RESTIC_REPOSITORY"
    restic init
  fi

  echo "==> Done. Test with 'sudo vps-backup run light', then 'sudo vps-backup schedule enable'."
}

cmd_status() {
  require_root
  load_config

  echo "== Version"
  echo "  $(vps_backup_version)"

  echo
  echo "== Schedule"
  schedule_status

  echo
  echo "== Latest snapshots (per tag)"
  if ! restic snapshots --compact --group-by tags --latest 3 2>/dev/null; then
    echo "  Repository not reachable or not initialized"
  fi

  echo
  echo "== Recent events ($LOG_FILE)"
  if [[ -f "$LOG_FILE" ]]; then
    # Hide output forwarded by run_logged (message indented by two spaces)
    { grep -vE '^[^ ]+ [^ ]+ \[[A-Z]+\] \[[^]]*\]   ' "$LOG_FILE" || true; } | tail -n 15
  else
    echo "  No log yet"
  fi
}

schedule_status() {
  if [[ -f "$CRON_FILE" ]]; then
    grep 'vps-backup run' "$CRON_FILE" | sed 's/^/  /' || true
  else
    echo "  Disabled"
  fi
}

cmd_schedule() {
  require_root
  load_config

  case "${1:-status}" in
    enable)
      if [[ -z "$LIGHT_SCHEDULE" && -z "$FULL_SCHEDULE" ]]; then
        die "$EXIT_CONFIG" "both LIGHT_SCHEDULE and FULL_SCHEDULE are empty"
      fi
      if [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then
        echo "Warning: $RESTIC_PASSWORD_FILE is missing, scheduled runs will fail until you run 'vps-backup init'" >&2
      fi

      {
        echo "# Managed by vps-backup: do not edit."
        echo "# Change LIGHT_SCHEDULE / FULL_SCHEDULE in $VPS_BACKUP_CONFIG, then run 'vps-backup schedule enable'."
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        if [[ -n "$LIGHT_SCHEDULE" ]]; then
          echo "$LIGHT_SCHEDULE root /usr/local/bin/vps-backup run light >> $LOG_DIR/cron.log 2>&1"
        fi
        if [[ -n "$FULL_SCHEDULE" ]]; then
          echo "$FULL_SCHEDULE root /usr/local/bin/vps-backup run full >> $LOG_DIR/cron.log 2>&1"
        fi
      } > "$CRON_FILE"
      chmod 600 "$CRON_FILE"

      echo "Schedule enabled:"
      schedule_status
      ;;
    disable)
      rm -f "$CRON_FILE"
      echo "Schedule disabled"
      ;;
    status)
      schedule_status
      ;;
    *)
      die "$EXIT_USAGE" "usage: vps-backup schedule enable|disable|status"
      ;;
  esac
}

cmd_restic() {
  require_root
  load_config
  require_commands restic
  exec restic "$@"
}

cmd_self_update() {
  require_root
  require_commands curl

  local installer_args=(--no-deps)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version|--ref)
        if [[ -z "${2:-}" ]]; then
          die "$EXIT_USAGE" "$1 requires a value"
        fi
        installer_args+=("$1" "$2")
        shift 2
        ;;
      *)
        die "$EXIT_USAGE" "usage: vps-backup self-update [--version X.Y.Z | --ref BRANCH]"
        ;;
    esac
  done

  local slug="${VPS_BACKUP_REPO:-$DEFAULT_REPO_SLUG}"
  curl -fsSL "https://raw.githubusercontent.com/$slug/main/install.sh" \
    | bash -s -- "${installer_args[@]}"
}
