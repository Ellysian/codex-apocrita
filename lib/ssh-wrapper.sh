#!/usr/bin/env bash
# Requires common.sh. Only the exact managed symlink is owned by the installer.

ca_is_ssh_shim() {
  local path="$1" target="$2" digest
  [[ -f "$path" ]] || return 1
  [[ "$path" -ef "$target" ]] && return 0
  cmp -s "$path" "$target" && return 0
  digest=$(LC_ALL=C ca_sha256 "$path")
  [[ "$digest" == 2c57fab5604c9a1328dedbe8fcbb6057a916007766b0ba15eae524b2f54fe57c ||
     "$digest" == 04f5e78a21398d3743c0f24390595bee755aee96d3085d68794d25e474dceb29 ]]
}

ca_find_ssh_executable() {
  local target="$1" remaining="$PATH" directory candidate saved=''
  local record
  record="$(ca_config_dir)/ssh-executable"
  if [[ -f "$record" ]]; then IFS= read -r saved < "$record" || saved=''; fi
  # Do not use command -v here: shell functions are not exec-able paths, and
  # our own managed shim may already be first in PATH on a repeat update.
  while :; do
    directory=${remaining%%:*}
    directory=$(cd -P "${directory:-.}" 2>/dev/null && pwd) || directory=''
    candidate="$directory/ssh"
    if [[ -n "$directory" && -f "$candidate" && -x "$candidate" ]]; then
      if ca_is_ssh_shim "$candidate" "$target"; then
        if [[ "$saved" == /* && -f "$saved" && -x "$saved" ]] && ! ca_is_ssh_shim "$saved" "$target"; then
          printf '%s\n' "$saved"; return 0
        fi
      else
        printf '%s\n' "$candidate"; return 0
      fi
    fi
    [[ "$remaining" == *:* ]] || break
    remaining=${remaining#*:}
  done
  return 1
}

ca_remove_ssh_wrapper() {
  local path="$HOME/.local/bin/ssh" target
  target="$(ca_data_dir)/current/bin/codex-apocrita-ssh"
  if [[ -L "$path" && "$(readlink "$path")" == "$target" ]]; then
    rm -f -- "$path"
    rm -f -- "$(ca_config_dir)/ssh-executable"
    ca_info 'Removed managed local SSH compatibility wrapper'
  fi
}

ca_sync_ssh_wrapper() {
  local mode="$1" alias="$2" path="$HOME/.local/bin/ssh" target backup stage real_ssh record temporary
  target="$(ca_data_dir)/current/bin/codex-apocrita-ssh"
  if [[ "$mode" == off || "$alias" != apocrita-codex || ! -x "$target" ]]; then
    ca_remove_ssh_wrapper
    if [[ "$mode" != off && "$alias" != apocrita-codex ]]; then
      ca_info 'SSH compatibility wrapper skipped: only the apocrita-codex alias is supported'
    fi
    return 0
  fi
  if [[ ( -e "$path" || -L "$path" ) && ! ( -L "$path" && "$(readlink "$path")" == "$target" ) ]]; then
    # Migrate only byte-for-byte copies of the two published/manual versions
    # or the current payload. An unrelated file, directory or symlink is never
    # replaced based on a filename, marker, or superficial content match.
    if [[ -f "$path" && ! -L "$path" ]] && ca_is_ssh_shim "$path" "$target"; then
      backup="$path.codex-apocrita.$(date +%Y%m%d-%H%M%S).$$.bak"
      cp -p "$path" "$backup"
      ca_info "Backed up the previous manual SSH shim: $backup"
    else
      ca_warn "SSH fix NOT enabled: preserving existing $path. Review it before installing the compatibility wrapper."
      return 0
    fi
  fi
  if ! real_ssh=$(ca_find_ssh_executable "$target") || [[ "$real_ssh" == *$'\n'* ]]; then
    ca_warn 'SSH fix NOT enabled: no usable SSH executable was found behind the compatibility shim.'
    return 0
  fi
  record="$(ca_config_dir)/ssh-executable"
  mkdir -p "$(ca_config_dir)"
  temporary=$(mktemp "$(ca_config_dir)/.ssh-executable.XXXXXX")
  printf '%s\n' "$real_ssh" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$record"
  if [[ -L "$path" && "$(readlink "$path")" == "$target" ]]; then
    ca_info "Local SSH compatibility wrapper is managed; SSH executable: $real_ssh"
    return 0
  fi
  mkdir -p "$HOME/.local/bin"
  stage=$(mktemp -d "$HOME/.local/bin/.codex-apocrita-ssh.XXXXXX")
  ln -s "$target" "$stage/ssh"
  mv -f "$stage/ssh" "$path"
  rmdir "$stage"
  ca_info "Installed managed local SSH compatibility wrapper; SSH executable: $real_ssh"
}
