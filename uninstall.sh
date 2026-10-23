#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT=$(cd -P "$(dirname "$0")" && pwd)
source "$SOURCE_ROOT/lib/common.sh"
source "$SOURCE_ROOT/lib/ssh-wrapper.sh"
purge_codex=0
CA_ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-codex) purge_codex=1 ;;
    --yes) CA_ASSUME_YES=1 ;;
    -h|--help) echo 'Usage: uninstall.sh [--purge-codex] [--yes]'; exit ;;
    *) ca_die "Unknown option: $1" ;;
  esac
  shift
done
ca_load_config "$(ca_config_dir)/config"
ca_confirm 'Remove codex-apocrita local and remote components?' || ca_die 'Uninstall cancelled.'

if ssh -O check "$CA_SSH_ALIAS" >/dev/null 2>&1 || ssh "$CA_SSH_ALIAS" true >/dev/null 2>&1; then
  # Deliberately expanded by the remote login shell.
  # shellcheck disable=SC2016
  remote_uninstall='${HOME}/.local/share/codex-apocrita/current/remote/uninstall-remote.sh'
  command="$remote_uninstall"
  [[ "$purge_codex" == 1 ]] && command="$command --purge-codex"
  # command is escaped before being passed to the remote shell.
  # shellcheck disable=SC2029
  ssh "$CA_SSH_ALIAS" "bash -lc $(printf '%q' "$command")"
else
  ca_warn 'Remote host is unavailable; remote files were not removed.'
fi

remove_block() {
  local file="$1" begin="$2" end="$3" tmp
  [[ -f "$file" ]] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/codex-apocrita-uninstall.XXXXXX")
  awk -v begin="$begin" -v end="$end" '$0==begin{skip=1;next} $0==end{skip=0;next} !skip{print}' "$file" > "$tmp"
  mv "$tmp" "$file"
}
remove_block "$HOME/.zshrc" '# >>> codex-apocrita >>>' '# <<< codex-apocrita <<<'
remove_block "$HOME/.bashrc" '# >>> codex-apocrita >>>' '# <<< codex-apocrita <<<'

ssh_main="$HOME/.ssh/config"
if [[ -f "$ssh_main" ]]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/codex-apocrita-ssh.XXXXXX")
  awk '$0!="Include ~/.ssh/codex-apocrita.conf"{print}' "$ssh_main" > "$tmp"
  mv "$tmp" "$ssh_main"
fi
rm -f -- "$HOME/.ssh/codex-apocrita.conf" "$HOME/.local/bin/$CA_COMMAND_NAME" \
  "$HOME/.local/share/zsh/site-functions/_$CA_COMMAND_NAME" \
  "$HOME/.local/share/bash-completion/completions/$CA_COMMAND_NAME"
ca_remove_ssh_wrapper
rm -rf -- "$(ca_config_dir)" "$(ca_state_dir)" "$(ca_data_dir)"
echo 'codex-apocrita was uninstalled. Timestamped configuration backups were preserved.'
