# Commands and profiles

The examples use the default command name `apo`. Help automatically uses a customized name.

## Jobs

```bash
apo                     # start or reuse cpu
apo start NAME          # start or reuse a named profile
apo switch NAME         # confirm, stop, and replace the current job
apo force               # restart SSH only; preserve the allocation
apo restart [NAME]      # confirm and replace the allocation
apo status
apo stop                # allocation only
apo off                 # allocation and SSH master
```

Only one Codex allocation is recorded per remote account. `switch` is explicit because it cancels the current job.

For a proposed way to give projects separate allocation lifecycles, see [Independent project controllers](independent-controllers-proposal.md). This is a design discussion, not an available command or installer option; it proposes explicit per-instance stop without automatic idle shutdown.

## Profiles

```bash
apo config
apo config show cpu
apo config create longday cpu
apo config set longday CPUS_PER_TASK=4 MEM=16G TIME=8:00:00
apo config delete longday
```

Supported keys:

```text
JOB_NAME PARTITION ACCOUNT CONSTRAINT GRES
NODES NTASKS CPUS_PER_TASK CPUS_PER_GPU
MEM MEM_PER_CPU TIME
```

GPU profiles are intentionally not created automatically because partitions, accounts, constraints, and entitlements vary. Create one only after confirming your access with Apocrita documentation or support.

## Connection

```bash
apo ssh status
apo ssh start
apo ssh force
apo ssh off
```

## Diagnostics

```bash
apo doctor
apo doctor --runtime
apo test-prompt
apo test-prompt PROFILE
apo logs 200
apo clean
```

`--runtime` requires a running allocation and prints the compute hostname, Slurm job ID, cgroup, CPU allowance, and temporary directory.

`apo test-prompt [PROFILE]` reads the installed remote profile and generates a strict prompt for a Codex root agent and one subagent. Its expected CPU, memory, and wall-time values therefore reflect the profile at the moment you run the command. Paste the prompt into a new remote Codex task after selecting the Codex-specific SSH connection. The diagnostic forbids elevated or unsandboxed fallback; this restriction applies only to the test prompt and does not change the user's ordinary approval controls.

`apo clean` removes state for expired jobs, their shared temporary directories, and failed installer staging directories older than one day. Successful installations remove their staging data immediately.

## Updates and rollback

```bash
apo update
apo rollback
```

Updates are manual. Installations made from a Git checkout retain its path; `apo update` fast-forwards that checkout and reruns the idempotent installer. Both local and remote integrations retain a `previous` symlink for rollback.

## Completion and help

After opening a new terminal, type `apo ` and press Tab. Bash and Zsh ask the installed completion function for candidates based on the words already typed; it suggests commands, relevant subcommands, remote profile names, and supported profile `KEY=` settings. This is local shell behavior and does not submit or execute the unfinished command. Profile-name completion performs only a noninteractive health check and reads names when the authenticated SSH master is already available; it never opens a password prompt. Use `apo --help` or `apo -h` to print the full command reference.
