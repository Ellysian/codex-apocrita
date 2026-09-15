# Proposal: independent project controllers

**Status: design proposal only.** The repository currently records one Codex allocation per remote account. This document proposes a separate allocation and lifecycle for each project instance. It does not add multi-instance commands or change the current installer, dispatcher, Windows adapter, or cleanup behavior.

## Purpose

A project can need a Codex controller while another project is finished. Independent controllers would let the user stop the finished project's allocation without cancelling the controller serving the other project. Each project would have its own CPU, memory, and wall-time reservation, so its backend and subagents would share only that project's controller allocation.

An instance is a project environment, not an individual message or necessarily one chat. Several related chats and their subagents could use one instance. Users could create a separate instance when they need a separate resource lifecycle.

There is deliberately **no automatic idle shutdown**. Legitimate gaps occur while a person reviews changes, waits for an independently submitted job, or prepares the next instruction. Silence in a chat does not establish that its allocation is no longer needed. The user explicitly stops an instance when finished; Slurm still enforces its wall-time limit. There is no automatic renewal or resource increase. Closing Desktop would not be a stop request.

## Boundaries

This is allocation and application-state separation, not a new security boundary. Instances would still run as the same HPC user and could share project files, storage, SSH authentication, account quotas, filesystem permissions, and cluster services. Their jobs may run on the same physical node. Separate allocations do not make account-wide limits or shared-service contention disappear.

Slurm would enforce each controller's resource request. Account-wide resource limits and site policy would still apply to the sum of all controller and scientific jobs. A controller with 2 CPUs, 8 GB of memory, and a 24-hour limit is one possible small starting example, **not a universal default or evidence that every workload fits**. Resource choices should reflect measured controller use and the site's available profiles. Changes require an explicit user choice.

The proposed controller runs the Codex backend, editing, and ordinary agent coordination. Scientific training, testing, inference, benchmarks, and data processing use separate saved batch payloads submitted from the authenticated login-side control path. Stopping a controller must target only its allocation; it must not cancel those independent scientific jobs.

## Connection and state layout

Each instance would have a stable SSH connection name, such as `apocrita-project-a` or `apocrita-project-b`. Both connections would use the usual authenticated login endpoint. They would select different reviewed instance contexts before launching the ordinary Codex dispatcher:

```text
Desktop project A -> SSH alias A -> instance A context -> allocation A -> Codex
Desktop project B -> SSH alias B -> instance B context -> allocation B -> Codex
                              authenticated login side
```

The route must identify the instance explicitly. A remote server cannot infer the client's local SSH alias from the login hostname. The implementation would need to carry the selected instance through the client integration and remote wrapper while preserving argument quoting, host-key checks, and noninteractive authentication behavior.

Each instance needs the following state:

| State | Proposed treatment |
| --- | --- |
| Effective `HOME` and `CODEX_HOME` | A private, persistent instance home, selected consistently for backend, proxy, and execution helpers. |
| XDG configuration and state roots | Separate profile, lifecycle lock, job pointer, submission evidence, and stop records. |
| Codex history and settings | Persistent per-instance storage, retained when an allocation stops or expires. |
| Permission profiles | Preserve the intended project permissions and their path bindings; selecting another home must not broaden access. |
| App-server socket and control files | Private instance paths, within the platform's socket path-length limit; never shared with another running instance. |
| Job temporary state | An instance-specific allocation directory with verified ownership and restricted permissions. |
| Codex internal temporary helpers | Node-local storage with a unique instance and allocation generation, using the upstream temporary-directory handling. |
| Authentication | Reuse the established user authentication through a reviewed reference mechanism; do not copy secrets into instance directories, deployment bundles, or logs. |

Setting only `CODEX_HOME` is insufficient for the current wrappers: they also derive paths from `HOME` and the XDG variables. Those values must agree across every process participating in an instance. Persistent configuration needs inspection for absolute paths, plugin references, and permissions that may still point to a previous home.

The node-local temporary target should have a stable, private name for a given instance and allocation generation on both login and compute hosts. The same pathname can refer to different local storage on those hosts. One process must not relink another running instance's temporary directory or clean its live helpers. Runtime directory names and cleanup ownership must remain unambiguous after a later allocation starts.

This design retains the unmodified upstream Codex protocol and the repository's temporary-directory fix. It does not require a custom protocol proxy or introduce a per-instance Codex version-management feature. Sharing an installed release is possible provided the selected contexts and release compatibility are verified.

## Explicit lifecycle

The following are operation requirements, not implemented CLI syntax. All scheduling and attachment occur through the authenticated login-side control path. An instance must not submit from its compute node or SSH back to a login node.

### Start

1. Validate the instance identity, private paths, and reviewed CPU-only controller profile. Acquire that instance's lifecycle lock.
2. Reconcile its recorded job and any unfinished submission attempt with scheduler evidence. Reuse a matching allocation; do not submit again after an ambiguous response.
3. For a new allocation, submit the saved controller batch payload with `sbatch` from the login side. Persist the submission identity and actual job ID before proceeding.
4. Wait for owned `RUNNING` state and verify the allocation matches the requested instance and resource contract. A pending allocation is a normal scheduler state, not an authentication failure.
5. Start the ordinary Codex backend with login-side `srun --jobid=JOB_ID --overlap` inside that verified allocation. Use the selected instance context and the upstream dispatch path.

The design must distinguish a live backend, an incomplete launch, and a stale socket. An unexplained socket or uncertain submission requires reconciliation, not an automatic replacement or duplicate backend.

### Status and reconnect

Status should report each instance's recorded job, scheduler state, resource request, and known connection state. It must distinguish a failed SSH authentication, an absent allocation, an expired allocation, and an unavailable backend. Reading status must not create a job or wake a Goal.

Reconnect should reuse a verified live allocation and its stable instance identity. An expired allocation requires an explicit new start. Backend health, chat history availability, and a running Goal are separate facts; restoring the connection must not automatically resume a paused or blocked Goal.

### Stop and cleanup

An explicit stop must identify both the instance and the **expected current job ID**. Under the instance lock, verify the job's owner and identity, reject a mismatched job ID, and cancel only that allocation. Never use a broad job-name or account-wide cancellation.

Confirm the allocation's terminal state before removing its job pointer or disposable runtime state. Scheduler-query failure or a missing queue row alone is insufficient proof that termination completed. Keep submission receipts, failure evidence, durable history, settings, and project files.

Clean only the confirmed stopped generation's managed sockets, temporary helpers, and job temporary directories after checking their resolved paths and ownership. Node-local cleanup must use a site-supported mechanism or happen while the job is terminating; it must not introduce direct SSH to a compute node. If cleanup cannot be verified, report it and preserve the pending cleanup record. A later cleanup must never remove a new generation's files.

## Preserving existing chats

Moving existing history requires a separate migration procedure. Quiesce the affected backend before copying or moving its persistent databases and rollout files. Preserve chat IDs, parent/subagent relationships, history, project paths, Goal objectives, budgets, and accumulated usage. Keep a recoverable original and verify the new instance through the actual Desktop connection before changing its sidebar association.

Two running instances must not write to the same migrated history database. Reconnecting to a copied history is not permission to create another chat or resume its Goal. Authentication must remain outside the copied history set.

## Review and acceptance before implementation is released

A future implementation should demonstrate:

- Two concurrently connected instances route to their own verified allocations, state roots, and app-server sockets.
- Actual root and subagent operations retain the intended project permissions and use the selected controller context.
- Stopping one instance leaves the other allocation and its connection usable; independent scientific jobs are preserved.
- Restarting Desktop reopens the original histories without creating duplicate backends or resuming Goals unexpectedly.
- Expiry, stale pointers, interrupted submission, uncertain scheduler responses, and repeated start/stop requests do not cause duplicate submission or cancel the wrong job.
- Cleanup removes only the stopped generation's disposable state and retains durable history; rollback restores the prior connection and history.
- Both the usual SSH client integration and the Windows adapter can select an instance without weakening their existing authentication and quoting checks.

The document itself supplies no executable implementation, new acceptance results, or guarantee that the current release passes these criteria. Local control-logic tests and an independent source review would precede a live test using explicit, limited allocations and the applicable HPC execution policy.
