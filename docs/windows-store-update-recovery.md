# Windows Store update recovery: follow-up evidence

This follow-up is based on upstream main
`254d4c6b792ba377298135ce09e51b1491f2eee9`. It changes the Windows launcher and
profile handshake only. The Slurm backend, resource defaults, SSH authentication,
proxy/version isolation and installation lifecycle are outside this patch.

## Reproduced failure and recovery

On 2026-09-15, an existing Windows installation resolved one healthy Store
package before activation, but Windows activated a newly registered package
version. The launcher's original exact-identity check rejected the new process.
The profile could also reject the earlier expected package while the lease was
still PENDING, before the launcher had registered the actual process.

The corrected local implementation re-resolved the official package registration,
verified it against the actual activation result, and published the corresponding
package, executable, PID and start time before marking the lease REGISTERED.
PENDING permitted bounded waiting, without granting an adapter environment.
The user subsequently launched Desktop 26.908.9136.0 successfully. A matching
scoped profile handshake and direct Desktop-origin adapter connections were
observed. Two existing remote chat histories were readable, and the user confirmed
their display from the sidebar. Raw identity, account, project and connection
records remain private.

Those observations establish recovery in that private installation. This PR
ports the logic into the generic public configuration and lease format; the
private installation is not a clean-install test of this exact public revision.
The successful launch after the repair did not itself reproduce a second Store
update during activation; the race transition is covered by local fixtures.

## Verification boundaries

Local follow-up results on Windows x64 and PowerShell 7.6.5:

| Check | Result |
| --- | --- |
| Build from the public worktree | Passed |
| SSH argument parser | 227 assertions passed |
| Static configuration | 14 cases passed |
| Raw-byte transport and cancellation | 17 cases passed |
| Activation guard and actual-script launcher flow | 40 cases passed |
| Profile guard and actual-script bounded wait loop | 48 cases passed |
| Temporary-profile installation and rollback fixture | Passed |
| Independent production-source review | No blocking findings |
| Git whitespace and privacy review | Passed |
| Local Windows PowerShell 5.1 profile fixture | Not run successfully: the current execution policy refused script execution; policy was not changed or bypassed |

An initial compilation attempt under the restricted local sandbox account could
not write its output. The ordinary Windows-user run subsequently built and passed
the core fixtures. No security-product configuration or live profile was changed.
The hosted Windows workflow separately runs the profile guard on PowerShell 5.1;
consult its result for this exact commit rather than treating the local refusal
as either a test pass or a code failure.

Local tests must cover both a valid registration change and rejection of
unregistered/mismatched activation metadata, failed identity reads, stale
processes and invalid leases. A PENDING lease must never grant the adapter PATH.
Launcher flow coverage must exercise updating the expected identity before the
REGISTERED lease write, and preserving failure handling when registration fails.
See [the test commands](windows-testing.md).

The full launcher flow fixture exercises successful recovery, PID reuse, a changed
executable and a process exiting after the handshake. The wait-loop fixture uses
the actual script loop to verify registration changes and timeouts. The existing
2.5-second registration wait and total hook budget remain bounded; slow official
package resolution can still cause a safe startup failure. These fixtures do not
establish timing reliability on every Windows installation.

The [2026-09-08 clean-install, restart and rollback record](windows-live-acceptance.md)
remains the record for that earlier revision. It has not been relabelled as a new
pass for this follow-up. A fresh public-revision installation, normal root/subagent
file work, concurrent tasks, full Desktop Quit/reconnect, and actual rollback
have not been repeated for this patch. No existing controller was stopped or
scientific workload executed to obtain local regression results.

The change does not add multiple-controller support or automatic idle shutdown.
