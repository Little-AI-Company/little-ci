#!/usr/bin/env bash

record_created_swapfile() {
  local swap_ownership_manifest="$1" runner_number="$2" swapfile_path="$3" ownership_record manifest_metadata
  local manifest_dir
  manifest_dir="$(dirname "$swap_ownership_manifest")"

  if [ -L "$manifest_dir" ] || [ -L "$swap_ownership_manifest" ]; then
    echo "refusing symlinked swap ownership state: $swap_ownership_manifest" >&2
    return 1
  fi
  if [ -e "$manifest_dir" ]; then
    manifest_metadata="$(stat -c '%u:%g:%a' "$manifest_dir")"
    [ "$manifest_metadata" = 0:0:700 ] || {
      echo "swap ownership directory must be root-owned mode 700: $manifest_dir" >&2
      return 1
    }
  else
    install -d -o root -g root -m 700 "$manifest_dir"
  fi
  if [ -e "$swap_ownership_manifest" ]; then
    [ -f "$swap_ownership_manifest" ] || {
      echo "swap ownership manifest is not a regular file: $swap_ownership_manifest" >&2
      return 1
    }
    manifest_metadata="$(stat -c '%u:%g:%a' "$swap_ownership_manifest")"
    [ "$manifest_metadata" = 0:0:600 ] || {
      echo "swap ownership manifest must be root-owned mode 600: $swap_ownership_manifest" >&2
      return 1
    }
  else
    install -o root -g root -m 600 /dev/null "$swap_ownership_manifest"
  fi

  ownership_record="$(printf '%s\t%s' "$runner_number" "$swapfile_path")"
  grep -Fqx "$ownership_record" "$swap_ownership_manifest" || \
    printf '%s\n' "$ownership_record" >> "$swap_ownership_manifest"
}

swapfile_is_manifest_owned() {
  local swap_ownership_manifest="$1" runner_number="$2" swapfile_path="$3" ownership_record manifest_dir manifest_metadata
  manifest_dir="$(dirname "$swap_ownership_manifest")"
  ownership_record="$(printf '%s\t%s' "$runner_number" "$swapfile_path")"

  [ ! -L "$manifest_dir" ] && [ ! -L "$swap_ownership_manifest" ] || return 1
  [ -d "$manifest_dir" ] && [ -f "$swap_ownership_manifest" ] || return 1
  manifest_metadata="$(stat -c '%u:%g:%a' "$manifest_dir")"
  [ "$manifest_metadata" = 0:0:700 ] || return 1
  manifest_metadata="$(stat -c '%u:%g:%a' "$swap_ownership_manifest")"
  [ "$manifest_metadata" = 0:0:600 ] || return 1
  grep -Fqx "$ownership_record" "$swap_ownership_manifest"
}

validate_owned_swapfile() {
  local swap_ownership_manifest="$1" runner_number="$2" swapfile_path="$3" expected_size_bytes actual_metadata
  local actual_size_bytes filesystem_signature

  swapfile_is_manifest_owned "$swap_ownership_manifest" "$runner_number" "$swapfile_path" || {
    echo "refusing existing unowned Little-CI swapfile: $swapfile_path" >&2
    return 1
  }
  [ -f "$swapfile_path" ] && [ ! -L "$swapfile_path" ] || {
    echo "owned swapfile must be a regular, non-symlink file: $swapfile_path" >&2
    return 1
  }
  actual_metadata="$(stat -c '%u:%g:%a' "$swapfile_path")"
  [ "$actual_metadata" = 0:0:600 ] || {
    echo "owned swapfile must be root-owned mode 600: $swapfile_path" >&2
    return 1
  }
  expected_size_bytes="$((SWAP_GB * 1024 * 1024 * 1024))"
  actual_size_bytes="$(stat -c '%s' "$swapfile_path")"
  [ "$actual_size_bytes" = "$expected_size_bytes" ] || {
    echo "owned swapfile has size ${actual_size_bytes}B; expected ${expected_size_bytes}B: $swapfile_path" >&2
    return 1
  }
  filesystem_signature="$(blkid -p -s TYPE -o value "$swapfile_path" 2>/dev/null)" || {
    echo "owned swapfile has no readable swap signature: $swapfile_path" >&2
    return 1
  }
  [ "$filesystem_signature" = swap ] || {
    echo "owned swapfile has invalid signature '$filesystem_signature': $swapfile_path" >&2
    return 1
  }
}

fstab_has_exact_swap_entry() {
  local swapfile_path="$1"
  awk -v swapfile_path="$swapfile_path" '
    $0 !~ /^[[:space:]]*#/ && NF == 6 &&
      $1 == swapfile_path && $2 == "none" && $3 == "swap" &&
      $4 == "sw" && $5 == "0" && $6 == "0" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' /etc/fstab
}

cleanup_pending_swapfile() {
  local swap_ownership_manifest="$1" runner_number="$2" swapfile_path="$3"
  [ -n "$swapfile_path" ] || return 0
  if ! swapfile_is_manifest_owned "$swap_ownership_manifest" "$runner_number" "$swapfile_path"; then
    rm -f -- "$swapfile_path"
  fi
}
