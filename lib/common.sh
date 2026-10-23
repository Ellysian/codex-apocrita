#!/usr/bin/env bash
# This library populates configuration globals for its callers.
# shellcheck disable=SC2034

ca_die() { printf 'codex-apocrita: %s\n' "$*" >&2; exit 1; }
ca_warn() { printf 'Warning: %s\n' "$*" >&2; }
ca_info() { printf '==> %s\n' "$*"; }

ca_require() {
  command -v "$1" >/dev/null 2>&1 || ca_die "Required command not found: $1"
}

ca_validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

ca_config_dir() { printf '%s/codex-apocrita\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
ca_state_dir() { printf '%s/codex-apocrita\n' "${XDG_STATE_HOME:-$HOME/.local/state}"; }
ca_data_dir() { printf '%s/codex-apocrita\n' "${XDG_DATA_HOME:-$HOME/.local/share}"; }

ca_load_config() {
  local file="${1:-$(ca_config_dir)/config}" key value
  [[ -r "$file" ]] || ca_die "Configuration not found: $file. Run install.sh first."
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      SSH_ALIAS) CA_SSH_ALIAS="$value" ;;
      BASE_HOST) CA_BASE_HOST="$value" ;;
      COMMAND_NAME) CA_COMMAND_NAME="$value" ;;
      ENDPOINT) CA_ENDPOINT="$value" ;;
      SOURCE_DIR) CA_SOURCE_DIR="$value" ;;
      SSH_WRAPPER) CA_SSH_WRAPPER="$value" ;;
      *) ca_warn "Ignoring unknown configuration key: $key" ;;
    esac
  done < "$file"
  : "${CA_SSH_ALIAS:?Missing SSH_ALIAS in $file}"
  : "${CA_COMMAND_NAME:=apo}"
}

ca_resolve_script() {
  local source="$1" dir
  while [[ -L "$source" ]]; do
    dir=$(cd -P "$(dirname "$source")" && pwd)
    source=$(readlink "$source")
    [[ "$source" == /* ]] || source="$dir/$source"
  done
  printf '%s\n' "$source"
}

ca_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else ca_die 'A SHA-256 tool (sha256sum, shasum, or openssl) is required.'
  fi
}

ca_confirm() {
  local prompt="$1" answer
  [[ "${CA_ASSUME_YES:-0}" == 1 ]] && return 0
  printf '%s [y/N] ' "$prompt"
  IFS= read -r answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}
