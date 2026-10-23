# Troubleshooting

Start with:

```bash
apo doctor
apo status
apo logs 200
```

## Codex shows `Permission denied (password)`

Codex Desktop cannot answer Apocrita's interactive password prompt, so it may report `Permission denied (password)` when no authenticated SSH master is available. Run `apo ssh force` in a terminal, finish authentication there, and reconnect Codex Desktop. Don't put the password in `sshpass`, an `expect` script, or a file.

### Terminal SSH works, but Desktop's proxy still requests a password

Some Desktop versions add `ControlPath=none` to the SSH connection used by the
Desktop tools bridge. This bypasses the authenticated master even when the
initial connection checks succeed. The managed local shim
`bin/codex-apocrita-ssh` removes that option only for destination
`apocrita-codex` when the command launches `app-server proxy`. Every other SSH
invocation is passed unchanged to `/usr/bin/ssh`; forwarding and authentication
options are preserved. Other aliases, including custom integration aliases,
are deliberately unaffected.

On macOS or Linux with `/usr/bin/ssh`, update normally:

```bash
apo update
apo ssh force
```

Then fully quit and reopen Desktop. Since v0.1.1, installation and `apo update`
automatically enable this fix for the exact `apocrita-codex` alias. The shell
startup block puts `~/.local/bin` first in PATH. Desktop needs to pick up that
PATH; simply reconnecting may retain its cached SSH executable.

The installer preserves unrelated files or symlinks at `~/.local/bin/ssh` and
prints `SSH fix NOT enabled` if one blocks installation. Review that conflict
before proceeding; do not blindly overwrite your existing wrapper. Recognized,
unmodified older copies of this project's shim are backed up and migrated to
a managed symlink. Custom Codex SSH aliases are deliberately not enabled.

This is a local-only workaround: it does not restart or replace the Slurm job,
change Codex permissions, or edit chat/project state. It deliberately retains
Desktop's `ControlMaster=no` and reverse-forwarding options; it only allows the
proxy to reuse the already authenticated socket. A missing or stale master
still requires `apo ssh force`. The managed symlink follows integration updates
automatically; there is no separate wrapper installation step.

To opt out, run this from the checkout (adjust the config path if you use XDG_CONFIG_HOME):

```bash
./install.sh --from-config ~/.config/codex-apocrita/config --ssh-wrapper off --yes --skip-auth
```

This removes only the managed
symlink and saves the opt-out for future updates. Uninstall also removes only
that managed link; unrelated files and timestamped backups are preserved.

## SSH: disconnected

Network changes invalidate a ControlMaster TCP connection. Run `apo` again. The job may still be running; `apo` reuses it after the new master is ready.

## App-server WebSocket closes with code 1006

Check:

```bash
apo doctor
apo logs 200
```

Common causes are an expired allocation, remote Codex missing from PATH, incomplete authentication, or shell output corrupting the protocol. Re-run the idempotent installer if the remote shell wrapper or dispatcher is missing.

## Subagents fail with `No such file or directory`

Run `apo doctor --runtime` and confirm `TMPDIR` points beneath:

```text
~/.local/state/codex-apocrita/tmp/job-JOB_ID
```

Also verify that Codex's disposable temporary tree is managed locally:

```bash
ssh apocrita 'readlink ~/.codex/tmp'
```

It should report `/tmp/codex-apocrita-UID/codex-tmp`, with your numeric uid in place of `UID`. If `apo logs` reports a missing `~/.codex/tmp/arg0/.../codex-linux-sandbox`, update or reinstall the integration. Do not use an unsandboxed fallback to declare the diagnostic successful.

## Bubblewrap reports a missing unrelated `/data/...` path

If normal commands fail with `bwrap: Can't bind mount ... No such file or directory`, stop acceptance testing and report the node name and exact error. Apocrita's mount metadata can expose inactive unrelated automounts to Bubblewrap even when the selected project is your home directory. Do not activate or inspect the named dataset to make the test pass, and do not use elevated or unsandboxed execution. This requires an upstream Codex/Bubblewrap fix or an Apocrita mount-configuration change.

If stderr says that direct runtime enforcement is incompatible with `--use-legacy-landlock`, update or reinstall the integration. That experimental workaround is unsafe for current Codex Desktop permission profiles and has been removed.

## Job remains pending

`apo` waits while Slurm reports `PENDING` or `CONFIGURING`. Use `squeue` on Apocrita to inspect the reason. You can interrupt the local wait without cancelling the job; `apo status` will still show it.

## Allocation expired

Run `apo`. Stale state is removed and a replacement allocation is submitted. Codex Desktop should reconnect after the backend starts.

## Remote download fails

Force local download and upload:

```bash
./install.sh --remote-install-mode upload
```

The package digest is checked locally and remotely.

## Host alias is missing in Desktop

Confirm it is concrete and resolvable:

```bash
ssh -G apocrita-codex | head
```

Pattern-only `Host *` entries are not discoverable as named hosts. Re-run the installer if the managed `Include ~/.ssh/codex-apocrita.conf` line is missing.
