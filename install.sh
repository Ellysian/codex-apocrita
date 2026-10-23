#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT=$(cd -P "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$SOURCE_ROOT/lib/common.sh"
source "$SOURCE_ROOT/lib/ssh-config.sh"
source "$SOURCE_ROOT/lib/codex-release.sh"
source "$SOURCE_ROOT/lib/remote-deploy.sh"
source "$SOURCE_ROOT/lib/ssh-wrapper.sh"

base_host=apocrita
base_host_supplied=0
ssh_alias=apocrita-codex
command_name=apo
endpoint=login.hpc.qmul.ac.uk
partition=compute
cpus=2
memory=8G
walltime=4:00:00
dry_run=0
skip_auth=0
install_mode=auto
from_config=''
preserve_profile=0
ssh_wrapper=auto
ssh_wrapper_supplied=0
CA_ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Connection:
  --base-host NAME           Existing SSH alias (auto-detected; fallback: apocrita)
  --ssh-alias NAME           New Codex Desktop alias (apocrita-codex)
  --endpoint login|vscode|HOST
  --command-name NAME        Installed local command (apo)

Default CPU profile:
  --partition NAME           Slurm partition (compute)
  --cpus N                   CPUs per task (2)
  --memory SIZE              Total memory (8G)
  --time DURATION            Wall time (4:00:00)

Behavior:
  --ssh-wrapper auto|off    Manage the local SSH compatibility fix (auto)
  --remote-install-mode auto|remote|upload
  --skip-auth                Do not run remote Codex device login
  --yes, --non-interactive   Accept defaults or supplied flags
  --dry-run                  Print the plan without changing files
  --from-config FILE         Reinstall/update using an existing config
  -h, --help

This installer never invokes sudo and never stores your SSH password.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-host) base_host="$2"; base_host_supplied=1; shift ;; --ssh-alias) ssh_alias="$2"; shift ;;
    --command-name) command_name="$2"; shift ;; --endpoint) endpoint="$2"; shift ;;
    --partition) partition="$2"; shift ;; --cpus) cpus="$2"; shift ;;
    --memory) memory="$2"; shift ;; --time) walltime="$2"; shift ;;
    --remote-install-mode) install_mode="$2"; shift ;; --skip-auth) skip_auth=1 ;;
    --ssh-wrapper) ssh_wrapper="$2"; ssh_wrapper_supplied=1; shift ;;
    --yes|--non-interactive) CA_ASSUME_YES=1 ;; --dry-run) dry_run=1 ;;
    --from-config) from_config="$2"; shift ;;
    -h|--help) usage; exit ;; *) ca_die "Unknown option: $1" ;;
  esac
  shift
done

if [[ -n "$from_config" ]]; then
  ca_load_config "$from_config"
  base_host="$CA_BASE_HOST"; ssh_alias="$CA_SSH_ALIAS"; command_name="$CA_COMMAND_NAME"; endpoint="$CA_ENDPOINT"
  preserve_profile=1
  [[ "$ssh_wrapper_supplied" == 1 ]] || ssh_wrapper="${CA_SSH_WRAPPER:-auto}"
fi

[[ "$(id -u)" -ne 0 ]] || ca_die 'Refusing to run as root. This installer is entirely user-local.'

case "$endpoint" in login) endpoint=login.hpc.qmul.ac.uk ;; vscode) endpoint=vscode.hpc.qmul.ac.uk ;; esac

prompt_value() {
  local label="$1" prompt="$2" current="$3" explanation="$4" notice="${5:-}" answer
  [[ "$CA_ASSUME_YES" == 1 ]] && { printf '%s\n' "$current"; return; }
  if [[ -t 2 && "${TERM:-dumb}" != dumb ]]; then
    printf '\n\033[1m== %s ==\033[0m\n\n' "$label" >&2
  else
    printf '\n== %s ==\n\n' "$label" >&2
  fi
  printf '%s\n' "$explanation" >&2
  [[ -z "$notice" ]] || printf '\n%s\n' "$notice" >&2
  printf '\n%s [default: %s]: ' "$prompt" "$current" >&2
  IFS= read -r answer; printf '%s\n' "${answer:-$current}"
}

if [[ "$CA_ASSUME_YES" != 1 && -z "$from_config" ]]; then
  detected_base_host=''
  if [[ "$base_host_supplied" != 1 ]]; then
    detected_base_host=$(ca_detect_apocrita_base_host "$HOME/.ssh/config" "$ssh_alias" 2>/dev/null || true)
    [[ -z "$detected_base_host" ]] || base_host="$detected_base_host"
  fi
  cat <<'EOF'
Codex Desktop on Apocrita — Setup

This setup connects Codex Desktop to Apocrita and runs its remote backend
inside a Slurm allocation instead of SSHing directly to compute nodes.

Press Enter at any prompt to keep the displayed default.
EOF
  base_host_notice='No matching alias was detected, so the fallback below is suggested. Replace it if your existing alias has another name.'
  if [[ -n "$detected_base_host" ]]; then
    base_host_notice="Detected an existing Apocrita SSH alias: $detected_base_host"
  fi
  base_host=$(prompt_value 'Existing SSH alias' 'Existing SSH alias' "$base_host" 'The installer searches ~/.ssh/config for an existing alias that connects to an Apocrita login or VS Code gateway. Enter the Host alias you already use; its effective username, private-key path, and SSH port will be copied into the new Codex connection.' "$base_host_notice")
  ssh_alias=$(prompt_value 'Codex SSH alias' 'New SSH alias' "$ssh_alias" 'This is the new SSH alias that you will enable in Codex Desktop. Choose an unused name, or press Enter to use the recommended default.')
  command_name=$(prompt_value 'Local command' 'Command name' "$command_name" 'This is the terminal command used to start, inspect, configure, and stop the Codex Slurm allocation.')
  endpoint_choice=$(prompt_value 'Login gateway' 'Gateway' login $'Codex needs a login-compatible Apocrita gateway to submit the Slurm job and act as a bridge to the allocated compute node.\n\nAvailable choices:\n  login     login.hpc.qmul.ac.uk — recommended and normally the most stable\n  vscode    vscode.hpc.qmul.ac.uk — an alternative that may be busier\n  HOSTNAME  another authorized login-compatible gateway\n\nNever enter a compute-node hostname.')
  case "$endpoint_choice" in login) endpoint=login.hpc.qmul.ac.uk ;; vscode) endpoint=vscode.hpc.qmul.ac.uk ;; *) endpoint="$endpoint_choice" ;; esac
  partition=$(prompt_value 'Default Slurm partition' 'Partition' "$partition" 'This is the partition where the default Codex job will run. The recommended choice is compute, which is available to all Apocrita users. You can create additional profiles later for partitions such as computeshort, sae, andrena, or apini when needed and when your account has access.')
  cpus=$(prompt_value 'Default CPU cores' 'CPU cores' "$cpus" 'This is the number of CPU cores available to the Codex Desktop backend, its agents and subagents, and commands they run in the default job. You can edit this profile or create profiles with different resources later.')
  memory=$(prompt_value 'Default memory' 'Memory' "$memory" 'This is the total memory available to the Codex Desktop backend, its agents and subagents, and commands they run in the default job. You can edit this profile or create larger profiles later.')
  walltime=$(prompt_value 'Default wall-time limit' 'Wall time' "$walltime" 'This is the maximum time the default Codex job may remain running. Four hours may be sufficient for ordinary sessions; eight hours may be more convenient for a full working day.')
fi

ca_validate_name "$base_host" || ca_die 'Invalid base SSH host name.'
ca_validate_name "$ssh_alias" || ca_die 'Invalid Codex SSH alias.'
ca_validate_name "$command_name" || ca_die 'Invalid command name.'
[[ "$endpoint" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || ca_die 'Invalid endpoint hostname.'
[[ "$cpus" =~ ^[1-9][0-9]*$ ]] || ca_die 'CPU count must be a positive integer.'
[[ "$memory" =~ ^[1-9][0-9]*([KMGT])?$ ]] || ca_die 'Memory must look like 8G.'
[[ "$walltime" =~ ^[0-9]+(-[0-9]+)?(:[0-9]{1,2}){1,2}$ ]] || ca_die 'Invalid Slurm time.'
[[ "$install_mode" == auto || "$install_mode" == remote || "$install_mode" == upload ]] || ca_die 'Invalid remote install mode.'
[[ "$ssh_wrapper" == auto || "$ssh_wrapper" == off ]] || ca_die 'SSH wrapper mode must be auto or off.'
[[ "$command_name" != ssh ]] || ca_die 'The local command cannot be named ssh; that path is reserved for SSH.'
for dependency in bash ssh scp awk sed tar curl mktemp; do ca_require "$dependency"; done
ssh -G "$base_host" >/dev/null 2>&1 || ca_die "SSH host '$base_host' cannot be resolved."

CA_SSH_FRAGMENT_TMP=$(mktemp "${TMPDIR:-/tmp}/codex-apocrita-ssh.XXXXXX")
ca_render_ssh_fragment "$base_host" "$ssh_alias" "$endpoint" "$CA_SSH_FRAGMENT_TMP"

if [[ ! -f "$HOME/.ssh/codex-apocrita.conf" && -f "$HOME/.ssh/config" ]] &&
   awk -v wanted="$ssh_alias" '$1=="Host" {for(i=2;i<=NF;i++) if($i==wanted) found=1} END{exit !found}' "$HOME/.ssh/config"; then
  ca_die "SSH alias '$ssh_alias' already exists outside the managed fragment. Choose --ssh-alias NAME."
fi
auth_summary='Existing login or device code'
[[ "$skip_auth" == 1 ]] && auth_summary='skip the Codex login check'
printf '\nInstallation plan\n\n'
printf '  %-20s %-34s %s\n' 'Setting' 'Selected value' 'Purpose'
printf '  %-20s %-34s %s\n' 'Local command' "$command_name" 'Manage the SSH connection and Slurm job'
printf '  %-20s %-34s %s\n' 'Codex SSH alias' "$ssh_alias" 'Enable this connection in Codex Desktop'
printf '  %-20s %-34s %s\n' 'Login gateway' "$endpoint" 'Submit the job and bridge Codex to it'
printf '  %-20s %-34s %s\n' 'Existing SSH alias' "$base_host" 'Copy the effective user, key, and port'
if [[ "$preserve_profile" == 1 ]]; then
  printf '  %-20s %-34s %s\n' 'CPU profile' 'Preserve installed values' 'Leave the remote profile unchanged'
else
  printf '  %-20s %-34s %s\n' 'Slurm partition' "$partition" 'Run the default Codex job here'
  printf '  %-20s %-34s %s\n' 'CPU cores' "$cpus" 'Limit the default job to this CPU allocation'
  printf '  %-20s %-34s %s\n' 'Memory' "$memory" 'Limit the default job to this memory allocation'
  printf '  %-20s %-34s %s\n' 'Wall-time limit' "$walltime" 'Set the maximum default job duration'
fi
printf '  %-20s %-34s %s\n' 'Codex installation' "$install_mode, user-local" 'Install in your home directory without sudo'
printf '  %-20s %-34s %s\n' 'Authentication' "$auth_summary" 'Use remote Codex authentication'
printf '  %-20s %-34s %s\n' 'SSH compatibility' "$ssh_wrapper" 'Manage ~/.local/bin/ssh for apocrita-codex only; preserve unrelated wrappers'
printf '\nNo sudo command will be run. No SSH password or Codex token will be copied.\n'

if [[ "$dry_run" == 1 ]]; then
  echo; echo 'Generated SSH fragment:'; cat "$CA_SSH_FRAGMENT_TMP"; rm -f "$CA_SSH_FRAGMENT_TMP"; exit
fi
ca_confirm 'Continue with installation?' || ca_die 'Installation cancelled.'

ca_install_ssh_include
rm -f "$CA_SSH_FRAGMENT_TMP"
ca_start_master "$ssh_alias"
ca_remote_install "$SOURCE_ROOT" "$ssh_alias" "$install_mode"

if [[ "$preserve_profile" != 1 ]]; then
  profile_tmp=$(mktemp "${TMPDIR:-/tmp}/codex-apocrita-profile.XXXXXX")
  cat > "$profile_tmp" <<EOF
JOB_NAME=codex-desktop
PARTITION=$partition
NODES=1
NTASKS=1
CPUS_PER_TASK=$cpus
MEM=$memory
TIME=$walltime
EOF
  scp -q "$profile_tmp" "$ssh_alias:.config/codex-apocrita/profiles/cpu.conf"
  rm -f "$profile_tmp"
fi

version=$(cat "$SOURCE_ROOT/VERSION")
data_root=$(ca_data_dir); config_root=$(ca_config_dir); release_dir="$data_root/releases/$version"
mkdir -p "$data_root/releases" "$config_root" "$HOME/.local/bin"
stage="$data_root/releases/.staging.$version.$$"; rm -rf "$stage"; mkdir -p "$stage"
for item in bin lib completions docs remote profiles README.md LICENSE VERSION install.sh uninstall.sh; do cp -R "$SOURCE_ROOT/$item" "$stage/"; done
chmod 755 "$stage/install.sh" "$stage/uninstall.sh" "$stage/bin/codex-apocrita" "$stage/bin/codex-apocrita-ssh" "$stage/remote/"*
rm -rf "$release_dir"; mv "$stage" "$release_dir"
[[ -L "$data_root/current" ]] && ln -sfn "$(readlink "$data_root/current")" "$data_root/previous"
ln -sfn "$release_dir" "$data_root/current"
ca_sync_ssh_wrapper "$ssh_wrapper" "$ssh_alias"
command_path="$HOME/.local/bin/$command_name"
if [[ -e "$command_path" || -L "$command_path" ]] &&
   [[ ! -L "$command_path" || "$(readlink "$command_path")" != *codex-apocrita/current/bin/codex-apocrita ]]; then
  mv "$command_path" "$command_path.codex-apocrita.$(date +%Y%m%d-%H%M%S).bak"
fi
ln -sfn "$data_root/current/bin/codex-apocrita" "$command_path"

cat > "$config_root/config" <<EOF
SSH_ALIAS=$ssh_alias
BASE_HOST=$base_host
COMMAND_NAME=$command_name
ENDPOINT=$endpoint
SOURCE_DIR=$SOURCE_ROOT
SSH_WRAPPER=$ssh_wrapper
EOF
chmod 600 "$config_root/config"

install_shell_block() {
  local file="$1" shell_kind="$2" begin='# >>> codex-apocrita >>>' end='# <<< codex-apocrita <<<' tmp
  touch "$file"
  cp -p "$file" "$file.codex-apocrita.$(date +%Y%m%d-%H%M%S).bak"
  tmp=$(mktemp "${TMPDIR:-/tmp}/codex-apocrita-shell.XXXXXX")
  awk -v begin="$begin" -v end="$end" '$0==begin{skip=1;next} $0==end{skip=0;next} !skip{print}' "$file" > "$tmp"
  mv "$tmp" "$file"
  cat >> "$file" <<'EOF'

# >>> codex-apocrita >>>
case "$PATH" in "$HOME/.local/bin"|"$HOME/.local/bin":*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
# <<< codex-apocrita <<<
EOF
  if [[ "$shell_kind" == zsh ]]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/codex-apocrita-zsh.XXXXXX")
    awk '
      $0=="# <<< codex-apocrita <<<" {
        print "fpath=(\"$HOME/.local/share/zsh/site-functions\" $fpath)"
        print "autoload -Uz compinit"
        print "compinit"
      }
      {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    tmp=$(mktemp "${TMPDIR:-/tmp}/codex-apocrita-bash.XXXXXX")
    awk -v command="$command_name" '
      $0=="# <<< codex-apocrita <<<" {
        print "completion=\"$HOME/.local/share/bash-completion/completions/" command "\""
        print "[[ -r \"$completion\" ]] && source \"$completion\""
        print "unset completion"
      }
      {print}
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi
}
case "${SHELL:-}" in */zsh) install_shell_block "$HOME/.zshrc" zsh ;; *) install_shell_block "$HOME/.bashrc" bash ;; esac

mkdir -p "$HOME/.local/share/zsh/site-functions" "$HOME/.local/share/bash-completion/completions"
sed "s/__APO_COMMAND__/$command_name/g" "$SOURCE_ROOT/completions/_apo" > "$HOME/.local/share/zsh/site-functions/_$command_name"
sed "s/__APO_COMMAND__/$command_name/g" "$SOURCE_ROOT/completions/apo.bash" > "$HOME/.local/share/bash-completion/completions/$command_name"

if [[ "$skip_auth" != 1 ]]; then
  if ! ssh -o BatchMode=yes "$ssh_alias" '$HOME/.local/bin/codex-direct login status' >/dev/null 2>&1; then
    ca_info 'Authenticate the remote Codex CLI with the displayed device code'
    ssh -t "$ssh_alias" '$HOME/.local/bin/codex-direct login --device-auth'
  fi
fi

cat <<EOF

Installation complete.

Fully quit and reopen Codex Desktop so it picks up the local SSH fix.
No Slurm allocation restart is required for this SSH compatibility change.

Open a new terminal (or export PATH="\$HOME/.local/bin:\$PATH"), then run:
  $command_name doctor
  $command_name
  $command_name doctor --runtime

In Codex Desktop, open Settings > Connections and enable the new connection:
  $ssh_alias

Optional: verify the complete Codex Desktop integration
  1. Start a new task and choose New remote project.
  2. Select $ssh_alias, choose an Apocrita workspace, and click Add project.
  3. In your local terminal, run: $command_name test-prompt
  4. Copy the complete generated prompt into the new Codex task.

The resulting JSON should end with "all_checks_pass":true.

Shell completion was installed. In a new terminal, type "$command_name " and
press Tab to see available commands, profiles, and resource settings. You can
also run "$command_name --help" or "$command_name -h" at any time.
EOF
