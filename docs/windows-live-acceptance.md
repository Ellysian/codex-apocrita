# Windows acceptance record, updated 2026-09-08

Status: local regression checks, a fresh-build SSH check, actual adapter
installation, upstream runtime activation, corrected Desktop launch, and Desktop
SSH connection passed. Two concurrent documentation turns completed with real
subagent review on that runtime. Desktop reply display, a second normal
restart/reconnect, and subsequent file access in both original tasks also passed.
Actual rollback, original-route reconnection, and subsequent document access
also passed. The requested live sequence is complete for this installation and
bounded documentation workload. The first launch failure during a Store update
and broader untested behavior are preserved below.

## Candidate and backend scope

The Windows branch is based on upstream
`29448229bcf1cca4aaf2f0fc61e713ad9f57bfba`, including its node-local Codex
temporary-directory handling. Runtime files, upstream shell tests, installation
scripts, and libraries have no changes relative to that base.
Upstream `main` was checked again on 2026-09-08 and still pointed to that commit.

The original clean build and installation used commit
`95ccdf1923803b20921e35a82a091945ee0ef027`. The 2026-09-08 follow-up changes only
the launcher, its local regression coverage, CI wiring, and documentation; that
correction is committed as `ca9a127a7fe5ba91eb7480a6ccd8874bafd5703c`. Live
retries use this launcher correction on the original clean installation; the
executable and installed profile hook are unchanged. The old backend proxy/version-home isolation
changes are absent from this branch and are retained only in a separate
experimental comparison branch. Their necessity after the upstream fix has not
been demonstrated: the ordinary root/subagent work, concurrent tasks, and
restart/reconnect described here succeeded without them. This observation is
limited to the tested workload. Their proxy homes still require deliberate cleanup after
the relevant clients and allocation are confirmed inactive.

## Verified local results

Environment: Windows 10 x64 (10.0.19045), PowerShell 7.6.5, Windows PowerShell
5.1.19041.6456, .NET Framework CLR 4.0.30319.42000, and WSL 2.

| Check | Observed result |
| --- | --- |
| SSH argument parser | 227 assertions passed |
| Static adapter configuration | 14 cases passed, invoked once by the core suite |
| Windows raw-byte transport | 17 cases passed |
| Desktop profile guard, PowerShell 7 | 33 cases passed |
| Activation guard and mocked failure lifecycle, PowerShell 7 | 22 cases passed on the launcher correction |
| Desktop profile guard, Windows PowerShell 5.1 | 33 cases passed |
| Installation/profile lifecycle fixtures | 14 named checks passed |
| Full upstream shell suite in local WSL | All 12 test files passed, exit 0 |
| Static PowerShell parsing and Git whitespace checks | Passed |

The WSL suite used a fresh source export, the existing non-root local Linux user,
disposable HOME/XDG trees, and mocked SSH, Slurm, and Codex commands. No real HPC
test was performed by that suite. Its existing mocked download warning and two
awk quoting warnings did not cause failures.

Some preliminary sandbox-context Windows runs were refused by fixture-output
permissions or the execution policy for that context. The unchanged supported
commands subsequently passed under the normal Windows account. No execution
policy, authentication rule, or ownership guard was disabled.

## Fresh source and real SSH check

A new private ASCII directory was populated from `git archive` of the tested
commit. The adapter was compiled there using the Windows .NET Framework compiler.
No production executable, installation state, or launch lease was copied.
A new local configuration referenced the existing authenticated WSL master.

The newly built adapter successfully carried a read-only scheduler query to the
authorized Apocrita login endpoint and returned `RUNNING` with exit 0. This
establishes a real adapter/WSL/OpenSSH/login round trip. It does not establish
Desktop origin, an app-server session, root/subagent execution, or a clean
installation of the new upstream runtime.

The initial read-only installation preflight refused the existing PowerShell profile
directories because they inherit additional write permissions. The refusal
occurred before profile or installed-configuration changes. The fresh executable
and its local configuration were retained for the maintenance test. The directory
permissions were subsequently handled through a scoped maintenance procedure
with preserved original profiles, ACLs, and runtime state. The actual fresh
installation and activation of the unmodified upstream runtime then completed
with verified postconditions. The installer guard was not weakened.

## First actual Desktop launch and correction

The user launched Desktop manually through the installed candidate. The startup
lease expected Store package `26.901.5280.0`; the newly opened process and current
official registration instead identified `26.901.6511.0`. The lease was marked
`FAILED`, no scoped profile handshake was recorded, and there was no new candidate
transport invocation. Desktop displayed an SSH public-key failure. The existing
authenticated WSL master remained available, so that message did not establish
an expired authentication session.

The correction moves package discovery after compilation/setup, retains exact
package/executable/new-process checks, reports mismatch reasons, and saves local
metadata-only launch receipts. A Store update can still race activation; the
launcher fails closed and asks for normal Quit/retry rather than adopting a
different process. Local tests cover the update mismatch, failed identity reads,
stale processes, and receipt/lease-write failures under strict error preferences.
No local fixture activated Desktop or accessed HPC. The original failed attempt
remains a failure; the subsequent manual retry is recorded separately below.

## Successful manual retry and ordinary task work

The user normally quit Desktop, reran the corrected candidate launcher, and
received `DESKTOP_STARTED_PROFILE_APPLIED` for Store package `26.901.6511.0`.
The user then confirmed that the SSH connection was connected. Independent local
inspection matched the new Desktop process identity/start time to the lease,
launch receipt, and `APPLIED` handshake. A running candidate adapter was a direct
child of that Desktop process. Its binary/configuration hashes matched the lease.
The launch receipt reported successful activation and package identity queries.

The launcher reports `remoteTransportVerified=false` because it verifies its
scoped environment only. The separate Desktop observation, live adapter process,
transport records, and login-side backend checks supply the SSH evidence.
Adapter logs deliberately omit PID/ancestry, so an individual log invocation ID
cannot be joined directly to an OS process ID; that join is not claimed.

Login-side inspection before and after the task work verified the same listener
and proxy steps in the existing owned, running CPU-only allocation. Their reviewed
arguments and runtime hashes matched the unmodified upstream release. No backend
proxy-home/version-isolation comparison patch was enabled for these turns.
The independent scientific submission worker remained stopped.

Two existing documentation tasks were resumed for one bounded turn each. Their
observed execution windows overlapped by approximately 228 seconds. Both performed
normal source/document reading, wrote three new English Markdown documents in
separate dated deliverable directories, incorporated an independent subagent's
review, and reread their files. Each root's rollout records an actual reviewer
spawn and subsequent exchanges, with a canonical reviewer name returned by the
tool. Separate numeric reviewer IDs are not claimed. All six files were then read
through the login-side control path and recorded with sizes and SHA-256 hashes.
Both turns completed and became idle. Scientific Goals were not resumed, and no
scientific test, benchmark, training, or compute-node probe was part of this work.

An observation-tool limitation was found: `read_thread` returned an empty item
list for these new turns, and `wait_threads` reported completion without final
text, while the scoped remote rollout files contained the actual replies and
tool events. This was not treated as proof that the agents had done no work.
The six produced files and saved final replies establish the documentation
outcome. The user subsequently confirmed that both original tasks display the
complete final replies and all three document links after the second restart.
No claim is made that the observation-API discrepancy is fixed.

## Second normal restart and same-task file access

The user normally quit Desktop and manually launched the same corrected
candidate again. The new process had a distinct launch ID and process identity.
Independent local inspection matched the successful receipt, official package
identity, and scoped `APPLIED` handshake to that new process. A live candidate
adapter was its direct child. Launcher, executable, and configuration hashes
were unchanged from the first successful launch.

The user confirmed the SSH connection and visible histories in both original
documentation tasks. Login-side inspection verified that the existing listener
remained in the same owned allocation and a new proxy step served the restarted
Desktop, still using the unmodified upstream runtime. The scientific submission
worker remained stopped.

Both original tasks then completed a bounded read-only follow-up that reread the
opening sections of their three documents and reported a substantive point from
the text. Scoped rollout records contain the new tool events and final replies.
Independent login-side reads confirmed that all six file hashes and sizes were
unchanged. Both tasks returned to idle. This establishes reconnect and continued
ordinary file access; it does not certify long-duration scientific Goal operation.

The recovery input check verified all 16 pinned operational files. The original
launcher and shortcut remained intact and resolved the current Store package.
Its profile hook was correctly reported absent while the candidate hook was
installed. These are read-only recovery readiness checks, not an actual rollback.

## Actual rollback and restored-route verification

The user normally quit Desktop and ran the preserved independent maintenance
entrypoint. It completed with `READY_FOR_MANUAL_ORIGINAL_LAUNCH`. The saved
Windows journal records successful candidate removal and original-hook
installation. A fresh read-only check verified both PowerShell profiles against
their original bytes and confirmed the directory ACL baseline matched, with no
reported restoration errors.
The candidate lease was disabled, and no live candidate adapter process remained.
The original launch's protected lease and receipt matched the new Desktop process,
which had a live original-adapter process as its direct child. The restored legacy
hook's handshake has inherited permissions; its SHA-256 matched the protected
receipt. This establishes restoration of that earlier installation, not adoption
of the candidate's stricter metadata permissions by the legacy hook.
The Windows SSH configuration hash matched its recorded baseline. No pre-test
user/machine PATH value or system OpenSSH binary-hash baseline was available, so
measured before/after equality for those items is not claimed. The reviewed
adapter integration does not write global PATH or replace system OpenSSH.

Login-side inspection verified `RESTORED` and the original runtime postconditions.
Fresh listener and proxy steps were correlated with the previous runtime in the
same preserved allocation. The user launched Desktop through the original
adapter, confirmed SSH reconnection, and opened the existing research and
documentation task histories, including the previously produced replies and links.

A bounded read-only continuation in the original documentation task successfully
read the quick-start file and reported its title and a factual point. All six
acceptance documents retained their prior sizes and hashes. The task returned
to idle. The independent scientific submission worker remained stopped; its
restart and renewed scientific Goal execution are outside this maintenance test.

The actual sequence restored the earlier installation and backend route;
candidate source, private configuration, and recovery evidence were retained.
It did not cancel or replace the controller allocation.

## Completed live acceptance matrix

| Required acceptance step | Current status |
| --- | --- |
| Build adapter from clean committed source | Passed |
| Install into the actual Desktop profile environment | Passed; actual installation postconditions verified |
| Activate unmodified upstream runtime | Passed; actual activation postconditions verified |
| Launch Desktop through the new adapter | Passed on corrected manual retry; original update-race failure retained |
| Connect Desktop to the rebased upstream runtime | Passed; user observation and local/login-side correlation |
| Normal root command and file work | Passed; two completed documentation turns and six verified files |
| Normal subagent command and file work | Passed; independent document reads/reviews for both roots |
| Two concurrent Desktop tasks | Passed for bounded documentation work; approximately 228 seconds of overlap |
| Latest task replies visible in Desktop | Passed; user confirmed both final replies and their document links after restart |
| Fully restart Desktop and resume the same tasks | Passed; distinct Desktop process, new proxy, and successful file reads in both original tasks |
| Roll back actual profile integration and restore the previous route | Passed; actual restore, profile bytes/ACL baseline, original runtime, SSH and document access verified |

During initial preparation, existing production tasks were left running. The new upstream wrapper prepares
`HOME/.codex/tmp`, so changing only `CODEX_HOME` is insufficient for a separate
test backend. An isolated HOME/runtime staging plan was prepared but not deployed.
The attempted non-secret SSH environment marker was not delivered through the
current authenticated connection; no server configuration or authentication was
changed to force it through. A Desktop-wide CLI override would also affect the
local backend and other SSH connections, so it was not installed as a workaround.
For actual maintenance, the user paused existing Codex work and the independent
submission worker. The scoped procedure preserved the allocation and recovery
baselines while replacing the previous backend route. Scientific Goals and the
independent submission worker remained paused after restoration; neither was
silently restarted as part of acceptance.

The reproducible procedure is described in [the Windows guide](windows-wsl.md#clean-install-restart-and-rollback-acceptance).
The sequence covers one Windows/WSL installation and bounded documentation work.
It does not certify long-duration unattended Goals, peak resource use, every
security product, future Desktop versions, or shutdown/sleep/network-loss
recovery. No scientific computation or compute-node acceptance probe was run.
Host identities, account names, research paths, job/task identifiers, raw
application logs, and credentials are excluded from this public record.
