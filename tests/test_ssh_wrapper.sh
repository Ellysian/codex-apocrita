#!/usr/bin/env bash
source "$(dirname "$0")/testlib.sh"
new_home
export CODEX_APOCRITA_SSH_REAL="$TEST_TMP/bin/real-ssh"
export SSH_WRAPPER_CAPTURE="$TEST_TMP/actual"
write_executable "$CODEX_APOCRITA_SSH_REAL" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$SSH_WRAPPER_CAPTURE"
exit "${SSH_WRAPPER_EXIT:-0}"
EOF
wrapper="$TEST_ROOT/bin/codex-apocrita-ssh"
run_wrapper() { "$BASH" "$wrapper" "$@"; }

unchanged() {
  printf '%s\0' "$@" > "$TEST_TMP/expected"
  run_wrapper "$@"
  cmp "$TEST_TMP/expected" "$SSH_WRAPPER_CAPTURE" || fail 'nonmatching SSH invocation changed'
}

unchanged -T -o ControlPath=none other-host 'exec codex app-server proxy'
unchanged -T -o ControlPath=none apocrita 'exec codex app-server proxy'
unchanged -T -o ControlPath=none apocrita-codex-direct 'exec codex app-server proxy'
unchanged -T -o ControlPath=none other-host echo apocrita-codex 'app-server proxy'
unchanged -T -o ControlPath=none apocrita-codex 'printf hello'
unchanged -G apocrita-codex
unchanged
unchanged -O check apocrita-codex
unchanged -T -o ControlPath=/custom/socket apocrita-codex 'exec codex app-server proxy'
unchanged -z -o ControlPath=none apocrita-codex 'exec codex app-server proxy'
unchanged -o
unchanged -p
unchanged -R apocrita-codex other-host 'exec codex app-server proxy'
unchanged -T -o ControlPath=none user@apocrita-codex 'exec codex app-server proxy'
unchanged -T -o ControlPath=none ssh://apocrita-codex 'exec codex app-server proxy'
unchanged -Tv -o ControlPath=none apocrita-codex 'exec codex app-server proxy'
unchanged -o ControlPathnone apocrita-codex 'exec codex app-server proxy'
unchanged -o 'ControlPath=n o n e' apocrita-codex 'exec codex app-server proxy'
unchanged -F apocrita-codex -o ControlPath=none other-host 'exec codex app-server proxy'
unchanged -i apocrita-codex -o ControlPath=none other-host 'exec codex app-server proxy'
unchanged -S apocrita-codex -o ControlPath=none other-host 'exec codex app-server proxy'

expected=(-T -o ControlMaster=no -o BatchMode=yes -o ExitOnForwardFailure=yes
  -R 127.0.0.1:32123:127.0.0.1:45678 apocrita-codex 'exec codex app-server proxy')
printf '%s\0' "${expected[@]}" > "$TEST_TMP/expected"
run_wrapper -T -o ControlMaster=no -o ControlPath=none -o BatchMode=yes \
  -o ExitOnForwardFailure=yes -R 127.0.0.1:32123:127.0.0.1:45678 \
  apocrita-codex 'exec codex app-server proxy'
cmp "$TEST_TMP/expected" "$SSH_WRAPPER_CAPTURE" || fail 'proxy options were not preserved'

for option in '-oControlPath=none' '-oCONTROLpath=NONE'; do
  printf '%s\0' apocrita-codex 'exec codex app-server proxy' > "$TEST_TMP/expected"
  run_wrapper "$option" apocrita-codex 'exec codex app-server proxy'
  cmp "$TEST_TMP/expected" "$SSH_WRAPPER_CAPTURE" || fail 'attached option was not removed'
done
run_wrapper -o 'ControlPath none' apocrita-codex 'exec codex app-server proxy'
cmp "$TEST_TMP/expected" "$SSH_WRAPPER_CAPTURE" || fail 'spaced option was not removed'

run_wrapper -o ' ControlPath = NONE ' apocrita-codex 'exec codex app-server proxy'
cmp "$TEST_TMP/expected" "$SSH_WRAPPER_CAPTURE" || fail 'whitespace around option was not handled'

printf '%s\0' -- apocrita-codex 'exec codex app-server proxy' > "$TEST_TMP/expected"
run_wrapper -o ControlPath=none -- apocrita-codex 'exec codex app-server proxy'
cmp "$TEST_TMP/expected" "$SSH_WRAPPER_CAPTURE" || fail 'end-of-options marker changed'

expected=(-F 'config path with spaces' -p 2222 -i 'key path with spaces' -l username
  -R 127.0.0.1:32123:127.0.0.1:45678 -o BatchMode=yes
  apocrita-codex 'exec codex app-server proxy')
printf '%s\0' "${expected[@]}" > "$TEST_TMP/expected"
run_wrapper -F 'config path with spaces' -p 2222 -i 'key path with spaces' -l username \
  -R 127.0.0.1:32123:127.0.0.1:45678 -o ControlPath=none -o BatchMode=yes \
  apocrita-codex 'exec codex app-server proxy'
cmp "$TEST_TMP/expected" "$SSH_WRAPPER_CAPTURE" || fail 'argument boundaries or connection settings changed'

run_wrapper -o ControlPath=none -F 'config path with spaces' -p 2222 \
  -i 'key path with spaces' -l username -R 127.0.0.1:32123:127.0.0.1:45678 \
  -o BatchMode=yes -oControlPath=none apocrita-codex 'exec codex app-server proxy'
cmp "$TEST_TMP/expected" "$SSH_WRAPPER_CAPTURE" || fail 'duplicate disabled control paths were not removed'

export SSH_WRAPPER_EXIT=37
if run_wrapper other-host; then fail 'exit status lost'; else
  [[ "$?" == 37 ]] || fail 'exit status changed'
fi
