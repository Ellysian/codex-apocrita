#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/slurm/bin:$HOME/.local/bin:$PATH"

remote_root="$HOME/.local/share/codex-apocrita"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/codex-apocrita"
config_root="${XDG_CONFIG_HOME:-$HOME/.config}/codex-apocrita"
upstream_bin="$remote_root/upstream-bin"
package_archive='' package_digest='' package_version='' package_target=''
mode=install

# shellcheck source=codex-runtime-common
source "$(dirname "$0")/codex-runtime-common"

die() { echo "codex-apocrita remote installer: $*" >&2; exit 1; }
[[ "$(id -u)" -ne 0 ]] || die 'Refusing to run as root. This installer never uses sudo.'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package_archive="$2"; shift ;;
    --digest) package_digest="$2"; shift ;;
    --codex-version) package_version="$2"; shift ;;
    --target) package_target="$2"; shift ;;
    --doctor) mode=doctor ;;
    --rollback) mode=rollback ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | sed 's/^.*= //'; fi
}

mkdir -p "$remote_root/releases" "$state_root" "$config_root/profiles" "$HOME/.local/bin" "$upstream_bin"
chmod 700 "$remote_root" "$state_root" "$config_root"
ca_prepare_codex_tmp

if [[ "$mode" == doctor ]]; then
  failed=0
  for command in bash ssh srun sbatch squeue scancel; do
    if command -v "$command" >/dev/null 2>&1; then printf '%-18s %s\n' "$command" "$(command -v "$command")"; else printf '%-18s missing\n' "$command"; failed=1; fi
  done
  if [[ -x "$HOME/.local/bin/codex-direct" ]]; then "$HOME/.local/bin/codex-direct" --version; "$HOME/.local/bin/codex-direct" login status || failed=1; else echo 'codex-direct: missing'; failed=1; fi
  "$remote_root/current/remote/codex-slurm-job" status || failed=1
  exit "$failed"
fi

if [[ "$mode" == rollback ]]; then
  [[ -L "$remote_root/previous" ]] || die 'No previous remote release is available.'
  current=$(readlink "$remote_root/current"); previous=$(readlink "$remote_root/previous")
  ln -sfn "$previous" "$remote_root/current"; ln -sfn "$current" "$remote_root/previous"
  echo "Remote integration rolled back to $(basename "$previous")."; exit
fi

install_official_online() {
  local installer
  command -v curl >/dev/null 2>&1 || return 1
  installer=$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX")
  curl -fsSL https://chatgpt.com/codex/install.sh -o "$installer" || { rm -f "$installer"; return 1; }
  PATH="$upstream_bin:$PATH" CODEX_INSTALL_DIR="$upstream_bin" CODEX_NON_INTERACTIVE=1 sh "$installer"
  rm -f "$installer"
}

install_uploaded_package() {
  local actual release_dir stage
  [[ -r "$package_archive" && -n "$package_digest" && -n "$package_version" && -n "$package_target" ]] || die 'Incomplete uploaded-package arguments.'
  actual=$(sha256_file "$package_archive"); [[ "$actual" == "$package_digest" ]] || die 'Uploaded Codex package checksum mismatch.'
  release_dir="$HOME/.codex/packages/standalone/releases/$package_version-$package_target"
  stage="$release_dir.staging.$$"; rm -rf "$stage"; mkdir -p "$stage"
  tar -xzf "$package_archive" -C "$stage"
  [[ -x "$stage/bin/codex" && -x "$stage/bin/codex-code-mode-host" ]] || die 'Uploaded package is incomplete.'
  mkdir -p "$(dirname "$release_dir")"; rm -rf "$release_dir"; mv "$stage" "$release_dir"
  mkdir -p "$HOME/.codex/packages/standalone" "$upstream_bin"
  ln -sfn "$release_dir" "$HOME/.codex/packages/standalone/current"
  ln -sfn "$HOME/.codex/packages/standalone/current/bin/codex" "$upstream_bin/codex"
}

if [[ -n "$package_archive" ]]; then install_uploaded_package
else install_official_online || die 'Online Codex installation failed. Re-run the local installer with --remote-install-mode upload.'
fi

version=$(cat "$(dirname "$0")/../VERSION" 2>/dev/null || cat "$(dirname "$0")/VERSION" 2>/dev/null || echo 0.1.0)
source_release=$(cd "$(dirname "$0")/.." && pwd)
release_dir="$remote_root/releases/$version"
stage="$remote_root/releases/.staging.$version.$$"; rm -rf "$stage"; mkdir -p "$stage"
cp -R "$source_release/remote" "$stage/remote"; cp "$source_release/VERSION" "$stage/VERSION"
chmod 755 "$stage/remote/"*
rm -rf "$release_dir"; mv "$stage" "$release_dir"
if [[ -L "$remote_root/current" && "$(readlink "$remote_root/current")" != "$release_dir" ]]; then
  ln -sfn "$(readlink "$remote_root/current")" "$remote_root/previous"
fi
ln -sfn "$release_dir" "$remote_root/current"

backup_conflict() {
  local path="$1" expected="$2" alternate="${3:-}" target=''
  [[ -L "$path" ]] && target=$(readlink "$path")
  [[ ! -e "$path" && ! -L "$path" || "$target" == *"$expected"* || -n "$alternate" && "$target" == *"$alternate"* ]] && return
  mv "$path" "$path.codex-apocrita.$(date +%Y%m%d-%H%M%S).bak"
}
backup_conflict "$HOME/.local/bin/codex-direct" 'codex-apocrita/current/remote/codex-direct' 'packages/standalone/current'
backup_conflict "$HOME/.local/bin/codex" 'codex-apocrita/current'
ln -sfn "$remote_root/current/remote/codex-direct" "$HOME/.local/bin/codex-direct"
ln -sfn "$remote_root/current/remote/codex-dispatch" "$HOME/.local/bin/codex"
ln -sfn "$remote_root/current/remote/codex-login-shell" "$HOME/.local/bin/codex-apocrita-login-shell"

if [[ ! -e "$config_root/profiles/cpu.conf" ]]; then cp "$source_release/profiles/cpu.conf" "$config_root/profiles/cpu.conf"; fi
chmod 600 "$config_root/profiles/"*.conf

add_block() {
  local file="$1" begin='# >>> codex-apocrita >>>' end='# <<< codex-apocrita <<<' tmp
  mkdir -p "$(dirname "$file")"; touch "$file"
  cp -p "$file" "$file.codex-apocrita.$(date +%Y%m%d-%H%M%S).bak"
  tmp=$(mktemp "${TMPDIR:-/tmp}/codex-apocrita-profile.XXXXXX")
  awk -v begin="$begin" -v end="$end" '$0==begin{skip=1;next} $0==end{skip=0;next} !skip{print}' "$file" > "$tmp"
  mv "$tmp" "$file"
  cat >> "$file" <<EOF

$begin
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) export PATH="\$HOME/.local/bin:\$PATH" ;; esac
$end
EOF
}
add_block "$HOME/.profile"; add_block "$HOME/.bash_profile"; add_block "$HOME/.bashrc"
if ! grep -Fq '# CODEX_APOCRITA_SHELL_WRAPPER' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'EOF'

# CODEX_APOCRITA_SHELL_WRAPPER
# Avoid interactive-shell job-control warnings corrupting Codex's SSH protocol.
if [[ $- != *i* && -n ${SSH_CONNECTION:-} ]]; then
  export CODEX_APOCRITA_REAL_SHELL="${CODEX_APOCRITA_REAL_SHELL:-/bin/bash}"
  export SHELL="$HOME/.local/bin/codex-apocrita-login-shell"
fi
# <<< CODEX_APOCRITA_SHELL_WRAPPER
EOF
fi

"$HOME/.local/bin/codex-direct" --version
echo 'Remote codex-apocrita installation complete.'
