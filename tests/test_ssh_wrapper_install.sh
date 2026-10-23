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
