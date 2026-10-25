#!/usr/bin/env bash
# "estimate" command: size of the light and full backups, without uploading anything.
# Uses the same configuration and exclusions as the backup itself.
# shellcheck disable=SC2154

human_size() {
  numfmt --to=iec --suffix=B "$1"
}

cmd_estimate() {
  require_root
  load_config
  require_commands docker du numfmt gzip

  local name engine size dir bytes path volume volume_path exclude
  local dumps_total=0 volumes_total config_total light_volumes_total=0

  echo "== Database dumps (gzip) =="
  while read -r name engine; do
    size=$(dump_database "$name" "$engine" 2>/dev/null | wc -c) || true
    if (( size < 1024 )); then
      echo "  $name: $(human_size "$size")  <-- WARNING: dump failed (check database credentials)"
    else
      echo "  $name: $(human_size "$size")"
    fi
    dumps_total=$((dumps_total + size))
  done < <(list_databases)

  build_excludes
  local du_excludes=()
  for exclude in "${EXCLUDES[@]}"; do
    du_excludes+=(--exclude="$exclude")
  done

  echo
  echo "== Largest volumes included in the full backup =="
  for dir in "$VOLUMES_ROOT"/*; do
    if [[ -d "$dir" ]]; then
      du -sb "${du_excludes[@]}" "$dir"
    fi
  done | sort -n | tail -10 | while read -r bytes path; do
    echo "  $(human_size "$bytes")  $(basename "$path")"
  done

  volumes_total=$(du -sb "${du_excludes[@]}" "$VOLUMES_ROOT" | cut -f1)
  config_total=$( (du -sbc "${CONFIG_PATHS[@]}" 2>/dev/null || true) | tail -1 | cut -f1)
  config_total=${config_total:-0}

  for volume in "${LIGHT_VOLUMES[@]}"; do
    if volume_path=$(docker volume inspect -f '{{.Mountpoint}}' "$volume" 2>/dev/null); then
      light_volumes_total=$((light_volumes_total + $(du -sb "$volume_path" | cut -f1)))
    fi
  done

  echo
  echo "== Large files in configuration paths (> 20MB) =="
  find "${CONFIG_PATHS[@]}" -type f -size +20M -exec du -h {} + 2>/dev/null || true

  echo
  echo "== Estimate (before restic compression and deduplication) =="
  echo "  Light: $(human_size $((config_total + light_volumes_total)))"
  echo "  Full:  $(human_size $((config_total + dumps_total + volumes_total)))"
}
