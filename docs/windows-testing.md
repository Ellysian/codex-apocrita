# Local Windows adapter tests

Run the following commands from `windows/wsl-ssh-adapter` on Windows
x64. These compile the adapter's own source and execute local fixtures. No HPC
connection, desktop activation, profile installation, or live configuration
changes are needed.

```powershell
pwsh -NoProfile -File .\tests\Run-CoreTests.ps1
pwsh -NoProfile -File .\tests\Test-DesktopProfileGuard.ps1
pwsh -NoProfile -File .\tests\Test-DesktopActivationGuard.ps1
powershell.exe -NoProfile -File .\tests\Test-DesktopProfileGuard.ps1
pwsh -NoProfile -File .\tests\Test-DesktopProfileLifecycle.ps1
```

The Windows workflow runs the same fixtures. If local execution policy prevents
a script from running, report that coverage as unavailable; do not change the
machine's execution policy just to obtain a passing test report.

## Parser and transport

Parser tests exercise configured target selection, unrelated-host fallback,
conflicting identity/port values, option arities, path validation, and enforced
noninteractive ControlMaster policies. Use fictional settings, including distinct
WSL and remote users. Transport tests cover raw bytes, simultaneous stdin/stdout/
stderr, command-line quoting, exit codes, and child-process cleanup.

Build fixtures from source. Generated executables and private adapter settings
must remain untracked.

## PowerShell and package activation

Profile tests use temporary profile paths and synthetic leases. Ordinary shells,
expired leases, mismatched process identity, untrusted files, and changed
configuration must not receive the adapter PATH. Pure activation tests inspect
arguments or use mocks; they must not activate the real Store app. Run guard tests
under Windows PowerShell 5.1 and PowerShell 7 where applicable.

The lifecycle fixture uses a copied same-user token with the user SID as the
default file owner, so it also runs on hosted administrator accounts whose default
owner is Administrators. This context is limited to the disposable fixture and
restored on exit; it does not change process privileges, account settings, or the
production ownership checks. The external compiler's single known fixture output
has its owner set explicitly inside that temporary tree, then passes the original
ownership and trusted-writer checks.

Installation regressions also verify that read-only preflight creates no state,
an invalid second profile does not change the first profile or adapter ACLs,
an untrusted parent for a missing profile is rejected without creating directories,
and a rejected top-level installation preserves existing configuration, profiles,
and installation records. Temporary wrapper scripts select only the fixture's
profiles; no actual Windows profile is read or edited by these tests.

## Manual integration

Local tests do not establish Store activation, actual desktop SSH discovery, or
scheduler ownership and placement. Collect the separate observations in the
[Windows guide](windows-wsl.md#verify-without-compute-probes). Do not run compute
probes where policy prohibits them.

Use the [clean-install and rollback procedure](windows-wsl.md#clean-install-restart-and-rollback-acceptance)
for live acceptance of a particular rebased revision. Record the exact adapter
commit and upstream backend commit separately. Do not include backend proxy-home
or version-isolation patches in the Windows acceptance baseline. If the backend
requires an independent fix, report that distinction rather than attributing it
to the adapter.

For each item, distinguish `PASS`, `FAIL`, and `NOT RUN`, and attach the observed
result. Record build/install, package activation, actual Desktop SSH, normal root
and subagent file work, concurrent tasks, reconnect after a normal Desktop restart,
and verified rollback separately. A procedure or a passing local fixture is not
evidence that any live item passed.

Before sharing failures, remove accounts, project paths, task contents, credentials,
and protocol payloads. Share a failing synthetic test name, sanitized error, and
relevant software versions.
