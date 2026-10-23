#!/usr/bin/env bash
source "$(dirname "$0")/testlib.sh"
new_home
mkdir -p "$XDG_CONFIG_HOME/codex-apocrita" "$XDG_DATA_HOME/codex-apocrita/releases/0.1.0" "$XDG_DATA_HOME/codex-apocrita/releases/0.0.9" "$TEST_TMP/source"
cat > "$XDG_CONFIG_HOME/codex-apocrita/config" <<EOF
SSH_ALIAS=apocrita-codex
BASE_HOST=apocrita
COMMAND_NAME=apo
ENDPOINT=login.hpc.qmul.ac.uk
SOURCE_DIR=$TEST_TMP/source
EOF
write_executable "$TEST_TMP/source/install.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$TEST_TMP/update-args'
EOF
write_executable "$TEST_TMP/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TEST_TMP/ssh-calls'
exit 0
EOF
ln -s "$XDG_DATA_HOME/codex-apocrita/releases/0.1.0" "$XDG_DATA_HOME/codex-apocrita/current"
ln -s "$XDG_DATA_HOME/codex-apocrita/releases/0.0.9" "$XDG_DATA_HOME/codex-apocrita/previous"
mkdir -p "$HOME/.local/bin" "$XDG_DATA_HOME/codex-apocrita/releases/0.1.0/bin"
cp "$TEST_ROOT/bin/codex-apocrita-ssh" "$XDG_DATA_HOME/codex-apocrita/releases/0.1.0/bin/"
# An older release may include the optional payload but not lifecycle management.
mkdir -p "$XDG_DATA_HOME/codex-apocrita/releases/0.0.9/bin"
cp "$TEST_ROOT/bin/codex-apocrita-ssh" "$XDG_DATA_HOME/codex-apocrita/releases/0.0.9/bin/"
ln -s "$XDG_DATA_HOME/codex-apocrita/current/bin/codex-apocrita-ssh" "$HOME/.local/bin/ssh"
bash "$TEST_ROOT/bin/codex-apocrita" update
assert_contains "$TEST_TMP/update-args" '--from-config'
assert_contains "$TEST_TMP/update-args" '--skip-auth'
bash "$TEST_ROOT/bin/codex-apocrita" rollback
[[ "$(readlink "$XDG_DATA_HOME/codex-apocrita/current")" == *0.0.9 ]] || fail 'local rollback did not swap releases'
assert_contains "$TEST_TMP/ssh-calls" '--rollback'
assert_absent "$HOME/.local/bin/ssh"

remote_data="$HOME/.local/share/codex-apocrita"
mkdir -p "$remote_data/releases/0.1.0" "$remote_data/releases/0.0.9"
ln -s "$remote_data/releases/0.1.0" "$remote_data/current"
ln -s "$remote_data/releases/0.0.9" "$remote_data/previous"
bash "$TEST_ROOT/remote/install-remote.sh" --rollback
[[ "$(readlink "$remote_data/current")" == *0.0.9 ]] || fail 'remote rollback did not swap releases'
