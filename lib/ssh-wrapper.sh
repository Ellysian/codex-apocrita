#!/usr/bin/env bash
# Requires common.sh. Only the exact managed symlink is owned by the installer.

ca_remove_ssh_wrapper() {
  local path="$HOME/.local/bin/ssh" target
  target="$(ca_data_dir)/current/bin/codex-apocrita-ssh"
  if [[ -L "$path" && "$(readlink "$path")" == "$target" ]]; then
    rm -f -- "$path"
    ca_info 'Removed managed local SSH compatibility wrapper'
  fi
}

ca_sync_ssh_wrapper() {
  local mode="$1" alias="$2" path="$HOME/.local/bin/ssh" target digest backup stage
  target="$(ca_data_dir)/current/bin/codex-apocrita-ssh"
  if [[ "$mode" == off || "$alias" != apocrita-codex || ! -x "$target" ]]; then
    ca_remove_ssh_wrapper
    if [[ "$mode" != off && "$alias" != apocrita-codex ]]; then
      ca_info 'SSH compatibility wrapper skipped: only the apocrita-codex alias is supported'
    fi
    return 0
  fi
  if [[ ! -x /usr/bin/ssh ]]; then
    ca_warn 'SSH compatibility wrapper skipped: /usr/bin/ssh is unavailable.'
    return 0
  fi
  if [[ -L "$path" && "$(readlink "$path")" == "$target" ]]; then
    ca_info 'Local SSH compatibility wrapper is managed and up to date'
    return 0
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    # Migrate only byte-for-byte copies of the two published/manual versions
    # or the current payload. An unrelated file, directory or symlink is never
    # replaced based on a filename, marker, or superficial content match.
    digest=''
    if [[ -f "$path" && ! -L "$path" ]]; then digest=$(ca_sha256 "$path"); fi
    if [[ -f "$path" && ! -L "$path" ]] &&
       { cmp -s "$path" "$target" ||
         [[ "$digest" == 2c57fab5604c9a1328dedbe8fcbb6057a916007766b0ba15eae524b2f54fe57c ||
            "$digest" == 04f5e78a21398d3743c0f24390595bee755aee96d3085d68794d25e474dceb29 ]]; }; then
      backup="$path.codex-apocrita.$(date +%Y%m%d-%H%M%S).$$.bak"
      cp -p "$path" "$backup"
      ca_info "Backed up the previous manual SSH shim: $backup"
    else
      ca_warn "SSH fix NOT enabled: preserving existing $path. Review it before installing the compatibility wrapper."
      return 0
    fi
  fi
  mkdir -p "$HOME/.local/bin"
  stage=$(mktemp -d "$HOME/.local/bin/.codex-apocrita-ssh.XXXXXX")
  ln -s "$target" "$stage/ssh"
  mv -f "$stage/ssh" "$path"
  rmdir "$stage"
  ca_info 'Installed managed local SSH compatibility wrapper (apocrita-codex proxy only)'
}
