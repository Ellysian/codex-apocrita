#!/usr/bin/env bash
source "$(dirname "$0")/testlib.sh"
new_home
source "$TEST_ROOT/lib/common.sh"
source "$TEST_ROOT/lib/ssh-wrapper.sh"
data=$(ca_data_dir)
mkdir -p "$data/releases/new/bin" "$data/releases/old" "$HOME/.local/bin"
cp "$TEST_ROOT/bin/codex-apocrita-ssh" "$data/releases/new/bin/"
ln -s "$data/releases/new" "$data/current"
path="$HOME/.local/bin/ssh"
target="$data/current/bin/codex-apocrita-ssh"

ca_sync_ssh_wrapper auto apocrita-codex
[[ -L "$path" && "$(readlink "$path")" == "$target" ]] || fail 'managed link not installed'
ca_sync_ssh_wrapper auto apocrita-codex
[[ -x "$path" ]] || fail 'repeat installation broke wrapper'
ca_sync_ssh_wrapper off apocrita-codex
assert_absent "$path"
ca_sync_ssh_wrapper auto custom-alias
assert_absent "$path"

cp "$TEST_ROOT/bin/codex-apocrita-ssh" "$path"
ca_sync_ssh_wrapper auto apocrita-codex
[[ -L "$path" ]] || fail 'manual copy not migrated'
backups=("$path".codex-apocrita.*.bak)
[[ "${#backups[@]}" == 1 ]] || fail 'expected one manual shim backup'
cmp "$TEST_ROOT/bin/codex-apocrita-ssh" "${backups[0]}" || fail 'backup changed original bytes'
ca_sync_ssh_wrapper auto apocrita-codex
backups=("$path".codex-apocrita.*.bak)
[[ "${#backups[@]}" == 1 ]] || fail 'repeat install made unnecessary backup'

# Rollback to a release without the wrapper must not leave a broken PATH entry.
ln -sfn "$data/releases/old" "$data/current"
ca_sync_ssh_wrapper auto apocrita-codex
assert_absent "$path"
ln -sfn "$data/releases/new" "$data/current"

# Never replace or remove an unrelated executable, even if it has our name.
printf '#!/bin/sh\n# codex-apocrita\nexit 42\n' > "$path"
cp "$path" "$TEST_TMP/unrelated"
ca_sync_ssh_wrapper auto apocrita-codex 2> "$TEST_TMP/conflict"
assert_contains "$TEST_TMP/conflict" 'SSH fix NOT enabled'
cmp "$path" "$TEST_TMP/unrelated" || fail 'unrelated file overwritten'
ca_remove_ssh_wrapper
ca_sync_ssh_wrapper off apocrita-codex
cmp "$path" "$TEST_TMP/unrelated" || fail 'unrelated file removed'
rm -- "$path"

ln -s "$TEST_TMP/missing" "$path"
ca_sync_ssh_wrapper auto apocrita-codex 2> "$TEST_TMP/conflict"
[[ "$(readlink "$path")" == "$TEST_TMP/missing" ]] || fail 'unrelated dangling symlink changed'
ca_remove_ssh_wrapper
[[ -L "$path" ]] || fail 'unrelated dangling symlink removed'
rm -- "$path"
mkdir "$path"
ca_sync_ssh_wrapper auto apocrita-codex 2> "$TEST_TMP/conflict"
[[ -d "$path" ]] || fail 'directory replaced'
rmdir "$path"

ca_sync_ssh_wrapper auto apocrita-codex
ca_remove_ssh_wrapper
assert_absent "$path"

# Preserve the real executable selected before PATH is changed, including
# spaces in paths, arbitrary argv, proxy flags, and its exit status.
custom_dir="$TEST_TMP/custom OpenSSH/bin"
export SSH_REAL_CAPTURE="$TEST_TMP/real-ssh-argv"
write_executable "$custom_dir/ssh" <<'EOF'
#!/bin/bash
printf '%s\0' "$@" > "$SSH_REAL_CAPTURE"
exit 23
EOF
custom_dir=$(cd -P "$custom_dir" && pwd)
export PATH="$custom_dir:$PATH"
ca_sync_ssh_wrapper auto apocrita-codex
record="$(ca_config_dir)/ssh-executable"
[[ "$(cat "$record")" == "$custom_dir/ssh" ]] || fail 'original SSH executable not captured'
export PATH="$HOME/.local/bin:$PATH"
printf '%s\0' -o ControlPath=none 'other-host' 'printf hello world' > "$TEST_TMP/expected-argv"
if "$path" -o ControlPath=none other-host 'printf hello world'; then
  fail 'custom SSH exit status lost'
else
  [[ "$?" == 23 ]] || fail 'custom SSH was not used'
fi
cmp "$TEST_TMP/expected-argv" "$SSH_REAL_CAPTURE" || fail 'unrelated SSH argv changed'
ca_sync_ssh_wrapper auto apocrita-codex
[[ "$(cat "$record")" == "$custom_dir/ssh" ]] || fail 'repeat update captured itself or system SSH'
printf '%s\0' -T apocrita-codex 'exec codex app-server proxy' > "$TEST_TMP/expected-argv"
if "$path" -T -o ControlPath=none apocrita-codex 'exec codex app-server proxy'; then
  fail 'custom proxy SSH exit status lost'
else
  [[ "$?" == 23 ]] || fail 'proxy did not use saved SSH'
fi
cmp "$TEST_TMP/expected-argv" "$SSH_REAL_CAPTURE" || fail 'proxy did not preserve options'

# Existing v0.1.1 links have no saved executable; recover by skipping our shim.
rm -- "$record"
if "$path" other-host > "$TEST_TMP/missing-record" 2>&1; then fail 'managed shim silently fell back to system SSH'; else
  [[ "$?" == 127 ]] || fail 'missing record did not fail clearly'
fi
ca_sync_ssh_wrapper auto apocrita-codex
[[ "$(cat "$record")" == "$custom_dir/ssh" ]] || fail 'old managed shim upgrade recursed'

# A stale or corrupt record must fail clearly instead of silently switching SSH.
printf '%s\n' "$TEST_TMP/nonexistent-ssh" > "$record"
if "$path" other-host > "$TEST_TMP/invalid-record" 2>&1; then fail 'missing SSH target accepted'; else
  [[ "$?" == 127 ]] || fail 'missing target did not fail clearly'
fi
assert_contains "$TEST_TMP/invalid-record" 'Saved SSH executable'
printf '%s\n' "$path" > "$record"
if "$path" other-host > "$TEST_TMP/recursive-record" 2>&1; then fail 'recursive target accepted'; else
  [[ "$?" == 127 ]] || fail 'recursive target did not fail clearly'
fi
ca_remove_ssh_wrapper
assert_absent "$record"
