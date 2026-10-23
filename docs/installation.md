# Installation reference

Run `install.sh` on the computer running Codex Desktop.

## Interactive setup

```bash
./install.sh
```

The wizard asks for:

- an existing SSH alias from which to copy the effective username, key, and port;
- a new concrete SSH alias discovered by Codex Desktop;
- a local management command name;
- login, VS Code, or a custom authorized endpoint;
- the default CPU profile.

It prints a complete review before changing files. Existing SSH and shell files receive timestamped backups.

## Options

```text
--base-host NAME
--ssh-alias NAME
--endpoint login|vscode|HOST
--command-name NAME
--partition NAME
--cpus N
--memory SIZE
--time DURATION
--remote-install-mode auto|remote|upload
--skip-auth
--ssh-wrapper auto|off
--yes | --non-interactive
--dry-run
--from-config FILE
-h | --help
```

`--from-config` is used by `apo update`; it preserves the existing remote CPU profile instead of restoring installer defaults.

`--ssh-wrapper auto` (the default, including upgrades from older configurations)
manages `~/.local/bin/ssh` for the exact `apocrita-codex` alias. This small local
shim lets Desktop's app-server proxy reuse the authenticated SSH master; other
destinations and nonmatching requests are passed unchanged to the SSH executable
already selected in your PATH. That absolute path is saved in the user-local
`ssh-executable` file, not forced to the system OpenSSH binary. Repeat updates
retain this selection when the managed shim is first in PATH.
Unrelated files or symlinks at that path are never replaced, and recognized
older manual copies are backed up before migration. Conflicts produce a clear
warning; custom aliases are skipped. Fully quit and reopen Desktop after an
update so it reloads its SSH executable and PATH.

Use `--ssh-wrapper off` to remove only the managed symlink and persist an
opt-out for future updates. Uninstall removes the managed link too. Rollback
to a release predating wrapper lifecycle management removes the link rather
than leaving an unmanaged or broken SSH command. This wrapper never changes
remote Codex authentication, histories, or permissions.

Example unattended installation:

```bash
./install.sh --non-interactive \
  --base-host apocrita \
  --ssh-alias apocrita-codex \
  --endpoint login \
  --command-name apo \
  --partition compute \
  --cpus 2 --memory 8G --time 4:00:00
```

`--endpoint login` selects `login.hpc.qmul.ac.uk`; `vscode` selects `vscode.hpc.qmul.ac.uk`. A custom endpoint must be an authorized login-compatible gateway, never a compute node as per ITSR's policy (unless you have private owned nodes).

## Codex installation modes

`auto` first runs OpenAI's official user-local standalone installer remotely. If the release service is unreachable from Apocrita, it downloads the correct Linux package locally, verifies the SHA-256 digest from official release metadata, uploads it, and verifies it again.

- `remote`: require remote download and fail if unavailable.
- `upload`: always use the verified local-download/upload path.

No mode invokes `sudo` or writes outside the remote home directory.

The remote account must use Bash for v0.1. Zsh is supported for the local management command and completions, but the installed remote shell wrapper delegates Codex's noninteractive SSH processes to `/bin/bash`.

## Shell completion

The installer generates completion definitions using the local command name you chose. Open a new terminal, type `apo `, and press Tab to complete commands. Completion also discovers remote profile names and suggests supported `KEY=` settings after `apo config set PROFILE `. Run `apo --help` or `apo -h` when you want the complete command list instead.

## Authentication

Unless `--skip-auth` is supplied, the installer checks `codex login status` remotely and starts `codex login --device-auth` when needed. Open the displayed URL locally and enter the one-time code.

The installer never copies `~/.codex/auth.json`, an API key, or an access token.

## Files

Local:

```text
~/.ssh/codex-apocrita.conf
~/.config/codex-apocrita/config
~/.config/codex-apocrita/ssh-executable  (saved SSH path, when wrapper enabled)
~/.local/share/codex-apocrita/
~/.local/bin/apo
~/.local/bin/ssh  (managed compatibility symlink, when enabled)
```

Remote:

```text
~/.local/bin/codex
~/.local/bin/codex-direct
~/.local/share/codex-apocrita/
~/.config/codex-apocrita/profiles/
~/.local/state/codex-apocrita/
~/.codex/packages/standalone/
```

## Manual remote installer

The primary installer deploys `remote/install-remote.sh` automatically. Advanced users can upload the repository's `remote`, `profiles`, and `VERSION` paths together and run that script on Apocrita. It expects the same relative layout and supports the uploaded-package flags used by the local fallback.
