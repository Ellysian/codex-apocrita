#!/usr/bin/env bash
source "$(dirname "$0")/testlib.sh"
new_home
export SHELL=/bin/bash
mkdir -p "$HOME/.ssh"
printf '# user setting\n' > "$HOME/.bashrc"
printf '# user ssh setting\nHost apocrita\n  HostName original.example\n' > "$HOME/.ssh/config"
write_executable "$TEST_TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -G ]]; then
  cat <<OUT
user abc123
hostname original.example
port 22
identityfile ~/.ssh/id_ed25519
controlpath ~/.ssh/test-control
OUT
  exit
fi
exit 0
EOF
write_executable "$TEST_TMP/bin/scp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TEST_TMP/scp.log'
EOF
write_executable "$TEST_TMP/bin/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TEST_TMP/sudo.log'
exit 99
EOF
real=$(command -v curl)
ln -s "$real" "$TEST_TMP/bin/curl"
run_install() {
  bash "$TEST_ROOT/install.sh" --yes --skip-auth --remote-install-mode remote \
    --base-host apocrita --ssh-alias apocrita-codex --command-name apo
}
bash "$TEST_ROOT/install.sh" --dry-run --yes --skip-auth --remote-install-mode remote \
  --base-host apocrita --ssh-alias apocrita-codex --command-name apo > "$TEST_TMP/dry-run"
assert_contains "$TEST_TMP/dry-run" 'Generated SSH fragment:'
assert_absent "$HOME/.ssh/codex-apocrita.conf"
assert_absent "$HOME/.local/bin/ssh"
assert_contains "$TEST_TMP/dry-run" 'SSH compatibility'
printf '\n\n\n\n\n\n\n\n' | bash "$TEST_ROOT/install.sh" --dry-run --skip-auth \
  --remote-install-mode remote > "$TEST_TMP/interactive" 2>&1
assert_contains "$TEST_TMP/interactive" 'Codex Desktop on Apocrita — Setup'
assert_contains "$TEST_TMP/interactive" '== Existing SSH alias =='
assert_contains "$TEST_TMP/interactive" 'No matching alias was detected'
assert_contains "$TEST_TMP/interactive" 'Existing SSH alias [default: apocrita]:'
assert_contains "$TEST_TMP/interactive" 'Submit the job and bridge Codex to it'
run_install > "$TEST_TMP/installed"
assert_contains "$TEST_TMP/installed" 'Optional: verify the complete Codex Desktop integration'
assert_contains "$TEST_TMP/installed" 'apo test-prompt'
assert_contains "$TEST_TMP/installed" '"all_checks_pass":true'
run_install
assert_file "$HOME/.ssh/codex-apocrita.conf"
assert_contains "$HOME/.ssh/codex-apocrita.conf" 'Host apocrita-codex'
assert_count 1 'Include ~/.ssh/codex-apocrita.conf' "$HOME/.ssh/config"
assert_count 1 '# >>> codex-apocrita >>>' "$HOME/.bashrc"
assert_contains "$HOME/.bashrc" '.local/share/bash-completion/completions/apo'
assert_file "$HOME/.local/share/bash-completion/completions/apo"
bash -n "$HOME/.local/share/bash-completion/completions/apo"
[[ -L "$HOME/.local/bin/apo" ]] || fail 'apo symlink missing'
[[ -L "$HOME/.local/bin/ssh" ]] || fail 'SSH shim symlink missing'
[[ "$(readlink "$HOME/.local/bin/ssh")" == "$XDG_DATA_HOME/codex-apocrita/current/bin/codex-apocrita-ssh" ]] || fail 'wrong SSH shim target'
PATH="/usr/bin:/bin:$HOME/.local/bin" /bin/bash -c 'source "$HOME/.bashrc"; [[ "${PATH%%:*}" == "$HOME/.local/bin" ]]' || fail 'shell block did not put the wrapper first'
bash "$TEST_ROOT/install.sh" --from-config "$XDG_CONFIG_HOME/codex-apocrita/config" \
  --yes --skip-auth --remote-install-mode remote > "$TEST_TMP/from-config"
assert_contains "$TEST_TMP/from-config" 'Preserve installed values'
assert_contains "$TEST_TMP/from-config" 'Leave the remote profile unchanged'
assert_count 2 '.config/codex-apocrita/profiles/cpu.conf' "$TEST_TMP/scp.log"

# Exercise the real apo update -> installer path with an old config and no shim.
rm -- "$HOME/.local/bin/ssh"
sed '/^SSH_WRAPPER=/d' "$XDG_CONFIG_HOME/codex-apocrita/config" > "$TEST_TMP/old-config"
mv "$TEST_TMP/old-config" "$XDG_CONFIG_HOME/codex-apocrita/config"
write_executable "$TEST_TMP/bin/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TEST_TMP/git.log'
exit 0
EOF
bash "$TEST_ROOT/bin/codex-apocrita" update > "$TEST_TMP/update"
assert_contains "$TEST_TMP/git.log" 'pull --ff-only'
[[ -L "$HOME/.local/bin/ssh" ]] || fail 'apo update did not install SSH fix for old config'
assert_contains "$XDG_CONFIG_HOME/codex-apocrita/config" 'SSH_WRAPPER=auto'
assert_contains "$TEST_TMP/update" 'Fully quit and reopen Codex Desktop'
assert_count 2 '.config/codex-apocrita/profiles/cpu.conf' "$TEST_TMP/scp.log"

bash "$TEST_ROOT/install.sh" --from-config "$XDG_CONFIG_HOME/codex-apocrita/config" \
  --yes --skip-auth --remote-install-mode remote --ssh-wrapper off > "$TEST_TMP/off"
assert_absent "$HOME/.local/bin/ssh"
bash "$TEST_ROOT/bin/codex-apocrita" update > "$TEST_TMP/off-update"
assert_absent "$HOME/.local/bin/ssh"
assert_contains "$XDG_CONFIG_HOME/codex-apocrita/config" 'SSH_WRAPPER=off'
bash "$TEST_ROOT/install.sh" --from-config "$XDG_CONFIG_HOME/codex-apocrita/config" \
  --yes --skip-auth --remote-install-mode remote --ssh-wrapper auto > "$TEST_TMP/on"
[[ -L "$HOME/.local/bin/ssh" ]] || fail 'explicit auto did not override saved off'
assert_absent "$TEST_TMP/sudo.log"
bash "$XDG_DATA_HOME/codex-apocrita/current/uninstall.sh" --yes
assert_absent "$HOME/.ssh/codex-apocrita.conf"
assert_absent "$HOME/.local/bin/apo"
assert_absent "$HOME/.local/bin/ssh"
assert_contains "$HOME/.bashrc" '# user setting'
assert_count 0 '# >>> codex-apocrita >>>' "$HOME/.bashrc"

# A user replacement is not ours to remove, even through the full uninstaller.
printf '#!/bin/sh\nexit 42\n' > "$HOME/.local/bin/ssh"
cp "$HOME/.local/bin/ssh" "$TEST_TMP/user-ssh"
run_install > "$TEST_TMP/conflict-install" 2>&1
assert_contains "$TEST_TMP/conflict-install" 'SSH fix NOT enabled'
cmp "$HOME/.local/bin/ssh" "$TEST_TMP/user-ssh" || fail 'installer changed unrelated SSH wrapper'
bash "$XDG_DATA_HOME/codex-apocrita/current/uninstall.sh" --yes
cmp "$HOME/.local/bin/ssh" "$TEST_TMP/user-ssh" || fail 'uninstaller removed unrelated SSH wrapper'
