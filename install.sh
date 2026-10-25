#!/usr/bin/env bash
# vps-backup installer: installs or updates vps-backup on a Debian/Ubuntu host.
# The configuration in /etc/vps-backup is never overwritten.
#
#   curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/vps-backup/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/SimoneCerruti/vps-backup/main/install.sh | sudo bash -s -- --version 1.0.0
set -Eeuo pipefail

REPO_SLUG="${VPS_BACKUP_REPO:-SimoneCerruti/vps-backup}"
INSTALL_DIR="${VPS_BACKUP_HOME:-/opt/vps-backup}"
CONF_DIR="/etc/vps-backup"
LOG_DIR="/var/log/vps-backup"
BIN_LINK="/usr/local/bin/vps-backup"
CRON_FILE="/etc/cron.d/vps-backup"
DEPENDENCIES=(restic rclone curl ca-certificates gzip tar util-linux coreutils logrotate cron)
REQUIRED_FILES=(
  vps-backup
  lib/common.sh
  lib/backup.sh
  lib/estimate.sh
  lib/commands.sh
  templates/logrotate
  vps-backup.conf.example
  VERSION
)

info() { echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install.sh [--version X.Y.Z | --ref BRANCH] [--no-deps]

  --version X.Y.Z   Install a tagged release (default: latest release)
  --ref BRANCH      Install from a branch instead of a release (development only)
  --no-deps         Do not install system packages
EOF
}

version="latest"
ref=""
install_deps=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ -n "${2:-}" ]] || die "--version requires a value"
      version="${2#v}"
      shift 2
      ;;
    --ref)
      [[ -n "${2:-}" ]] || die "--ref requires a value"
      ref="$2"
      shift 2
      ;;
    --no-deps)
      install_deps=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (pipe into 'sudo bash')"

# --- Dependencies ---
if $install_deps; then
  command -v apt-get >/dev/null 2>&1 \
    || die "apt-get not found: only Debian/Ubuntu are supported (use --no-deps to skip)"
  info "Installing dependencies: ${DEPENDENCIES[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${DEPENDENCIES[@]}" >/dev/null
fi
for cmd in curl tar; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

# --- Resolve what to download ---
if [[ -n "$ref" ]]; then
  label="$ref"
  archive_url="https://github.com/$REPO_SLUG/archive/refs/heads/$ref.tar.gz"
else
  if [[ "$version" == "latest" ]]; then
    tag=$(curl -fsSL "https://api.github.com/repos/$REPO_SLUG/releases/latest" \
      | grep -m1 '"tag_name"' \
      | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/') || true
    [[ -n "${tag:-}" ]] || die "could not resolve the latest release of $REPO_SLUG (use --version or --ref)"
  else
    tag="v$version"
  fi
  label="$tag"
  archive_url="https://github.com/$REPO_SLUG/archive/refs/tags/$tag.tar.gz"
fi

# --- Download and validate ---
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

info "Downloading $REPO_SLUG@$label"
curl -fsSL "$archive_url" | tar -xz -C "$tmp_dir" --strip-components=1 \
  || die "download failed: $archive_url"

for file in "${REQUIRED_FILES[@]}"; do
  [[ -f "$tmp_dir/$file" ]] || die "unexpected archive layout, missing: $file"
done
# Libraries added after 1.0 are checked from the entrypoint, so older releases still install
while read -r file; do
  [[ -f "$tmp_dir/$file" ]] || die "unexpected archive layout, missing: $file"
done < <(grep -oE 'lib/[a-z_-]+\.sh' "$tmp_dir/vps-backup" | sort -u)
for script in "$tmp_dir/vps-backup" "$tmp_dir"/lib/*.sh; do
  bash -n "$script" || die "syntax check failed: ${script#"$tmp_dir"/}"
done

# --- Install code (atomic swap, previous version kept in $INSTALL_DIR.old) ---
staging_dir="$INSTALL_DIR.new"
rm -rf "$staging_dir"
mkdir -p "$staging_dir"
cp -r "$tmp_dir/vps-backup" "$tmp_dir/lib" "$tmp_dir/templates" \
  "$tmp_dir/vps-backup.conf.example" "$tmp_dir/VERSION" "$staging_dir/"
chmod -R go-rwx "$staging_dir"
chmod 700 "$staging_dir/vps-backup"

if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR.old"
  mv "$INSTALL_DIR" "$INSTALL_DIR.old"
fi
mv "$staging_dir" "$INSTALL_DIR"
ln -sfn "$INSTALL_DIR/vps-backup" "$BIN_LINK"

# --- Config, logs, logrotate (config is never overwritten) ---
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
new_config=false
if [[ ! -f "$CONF_DIR/vps-backup.conf" ]]; then
  install -m 600 "$INSTALL_DIR/vps-backup.conf.example" "$CONF_DIR/vps-backup.conf"
  new_config=true
fi

mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"
install -m 644 "$INSTALL_DIR/templates/logrotate" /etc/logrotate.d/vps-backup

# Leftovers of the manual setup that preceded this tool
rm -f /usr/local/bin/vps-backup-estimate /usr/local/bin/vps-backup.sh /usr/local/bin/vps-backup-estimate.sh

info "vps-backup $(cat "$INSTALL_DIR/VERSION") installed in $INSTALL_DIR"

if $new_config; then
  cat <<EOF

Next steps:
  1. Edit the configuration:          sudo nano $CONF_DIR/vps-backup.conf
  2. Configure the rclone remote:     sudo rclone config      (see README, "Google Drive")
  3. Create password and repository:  sudo vps-backup init
     Disaster recovery: put the existing password in $CONF_DIR/restic-password first
  4. Check sizes and test:            sudo vps-backup estimate && sudo vps-backup run light
  5. Enable the schedule:             sudo vps-backup schedule enable
EOF
else
  info "Existing configuration kept: $CONF_DIR/vps-backup.conf"
  info "Compare it with $INSTALL_DIR/vps-backup.conf.example for new options"
  if [[ -f "$CRON_FILE" ]]; then
    if "$BIN_LINK" schedule enable >/dev/null; then
      info "Schedule refreshed"
    fi
  fi
fi
