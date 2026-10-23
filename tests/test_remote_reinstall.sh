#!/usr/bin/env bash
source "$(dirname "$0")/testlib.sh"
new_home
fixture="$TEST_TMP/remote-source"
mkdir -p "$fixture"
cp -R "$TEST_ROOT/remote" "$TEST_ROOT/profiles" "$fixture/"
export FIXTURE_INSTALLER="$TEST_TMP/official-installer"
write_executable "$FIXTURE_INSTALLER" <<'EOF'
#!/bin/sh
mkdir -p "$CODEX_INSTALL_DIR"
printf '#!/bin/sh\nprintf "codex fixture\\n"\n' > "$CODEX_INSTALL_DIR/codex"
chmod 755 "$CODEX_INSTALL_DIR/codex"
EOF
write_executable "$TEST_TMP/bin/curl" <<'EOF'
#!/bin/bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then cp "$FIXTURE_INSTALLER" "$2"; exit; fi
  shift
done
exit 1
EOF

data="$HOME/.local/share/codex-apocrita"
printf '0.0.8\n' > "$fixture/VERSION"
bash "$fixture/remote/install-remote.sh"
printf 'old remote payload\n' > "$data/releases/0.0.8/keep"
assert_absent "$data/previous"
printf '0.1.2\n' > "$fixture/VERSION"
bash "$fixture/remote/install-remote.sh"
[[ "$(readlink "$data/previous")" == "$data/releases/0.0.8" ]] || fail 'remote upgrade did not save older release'
bash "$fixture/remote/install-remote.sh"
[[ "$(readlink "$data/current")" == "$data/releases/0.1.2" ]] || fail 'repeat install changed current version'
[[ "$(readlink "$data/previous")" == "$data/releases/0.0.8" ]] || fail 'remote repeat install overwrote rollback target'
assert_contains "$data/releases/0.0.8/keep" 'old remote payload'
bash "$fixture/remote/install-remote.sh" --rollback
[[ "$(readlink "$data/current")" == "$data/releases/0.0.8" ]] || fail 'remote rollback after repeat did not restore older version'
assert_contains "$data/current/keep" 'old remote payload'
