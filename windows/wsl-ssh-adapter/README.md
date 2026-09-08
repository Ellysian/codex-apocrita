# Windows WSL SSH adapter

An optional source-built adapter for the Windows desktop app and an already
authenticated WSL OpenSSH master. It preserves a byte stream to the existing
codex-apocrita backend and uses native Windows SSH for other supported destinations.

Read the [Windows setup guide](../../docs/windows-wsl.md) before installation.
Use the [local test guide](../../docs/windows-testing.md) for parser, transport,
configuration, and profile fixtures. Real desktop/WSL/HPC acceptance is a separate
manual step. Source compilation and local mock tests do not require an HPC account.

Copy `adapter-config.example.json` to an ignored local `adapter-config.json` and
replace its fictional values. Never publish that private file or generated state.
Build with `Build.ps1`, inspect with `Install-Adapter.ps1 -ConfigPath ... -CheckOnly`,
and use the documented install/launch/removal commands after reviewing their scope.

This directory is covered by the repository's [MIT license](../../LICENSE).
