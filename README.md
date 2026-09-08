# codex-apocrita

Run [Codex Desktop](https://learn.chatgpt.com/docs/remote-connections#connect-to-an-ssh-host) against your Apocrita files while the Codex backend and every command it launches run inside your own Slurm allocation.

`codex-apocrita` uses a login host only as a control connection. It does **not** SSH directly to compute nodes, store your Apocrita password, or require administrator access.

## What you need

- Codex Desktop on your computer.
- macOS or Linux with `bash`, OpenSSH, `curl`, and `tar`.
- An existing working Apocrita entry in `~/.ssh/config`, for example `Host apocrita`, with your username and private key.
- Permission to submit jobs to Apocrita's `compute` partition.
- A ChatGPT/Codex account you can authenticate on the remote host.

Windows users can build the optional [experimental Windows/WSL adapter](docs/windows-wsl.md)
to reuse an already authenticated WSL SSH master. This has a separate Windows
installation and local test workflow; the main shell installer still runs in WSL.

## Install

Clone this repository, inspect the installer, and run it locally, not on Apocrita:

```bash
git clone https://github.com/Ellysian/codex-apocrita.git
cd codex-apocrita
./install.sh
```

The installer detects a likely existing Apocrita SSH alias when possible and explains each choice. Its defaults are:

- local command: `apo`;
- Codex SSH host: `apocrita-codex`;
- endpoint: `login.hpc.qmul.ac.uk`;
- default job: 2 CPUs, 8G memory, 4 hours on `compute`.

The default job is intentionally lean. Change it for your work; an eight-hour limit may be more convenient for a full working day.

The installer will ask for your normal Apocrita authentication to establish a reusable SSH connection. It may then show a Codex device code. It never records either credential.

Preview all changes without installing:

```bash
./install.sh --dry-run
```

See [Installation and every installer option](docs/installation.md) for unattended setup, alternate endpoints, and clusters without outbound internet.

## Connect Codex Desktop

After installation:

```bash
apo doctor
apo
```

Wait until the job reports `Ready`. Then in Codex Desktop:

1. Open **Settings → Connections → SSH**.
2. Enable or add the new `apocrita-codex` connection (or the new alias you chose during setup). Do not select your usual `apocrita` login or VS Code connection.
3. Start a new task, choose **New remote project**, select `apocrita-codex`, select any Apocrita workspace, and click **Add project**.

Generate a verification prompt from the resources currently stored in your profile, then paste it into the new task:

```bash
apo test-prompt
```

Codex must return one JSON object. The root agent and its subagent should share the compute node, Slurm job, CPU allocation, and temporary directory; every check should be `true`.

## Where your work runs

The entire remote Codex session runs inside the requested Slurm job on its assigned compute node. This includes the app-server, agents and subagents, terminal commands, repository inspection, builds, and tests launched by Codex. Slurm applies the job's CPU and memory limits, so these processes cannot consume compute resources allocated to another user's job.

The default 2-CPU, 8G profile is intended for interactive agent work: navigating repositories, reading files, spawning a few subagents, editing code, and running modest checks. It is not a substitute for scheduling substantial computation.

For large parallel CPU workloads, model training, simulations, or GPU work, submit a normal Apocrita job with `sbatch`, `srun`, or your usual scheduler workflow. Codex can prepare and submit those jobs from its allocation, but the heavy work should run in a separately requested Slurm allocation with appropriate resources.

## Everyday commands

```bash
apo                 # start or reuse the CPU job
apo status          # show SSH and Slurm status
apo stop            # stop the job, keep SSH ready
apo off             # stop the job and SSH connection
apo doctor --runtime
```

Change the default profile:

```bash
apo config show cpu
apo config set cpu CPUS_PER_TASK=4 MEM=24G TIME=8:00:00
```

Create another profile and switch to it:

```bash
apo config create bigcpu cpu
apo config set bigcpu CPUS_PER_TASK=8 MEM=48G TIME=8:00:00
apo switch bigcpu
```

Run `apo --help` for the full command list and see the [usage guide](docs/usage.md).

## Update or remove

From an installation made with a Git checkout:

```bash
apo update
```

This performs a fast-forward source update, installs the new integration atomically, and updates the official remote Codex CLI. Use `apo rollback` to return to the previous integration release.

Uninstall:

```bash
apo uninstall
```

The official Codex package is preserved by default. Use `./uninstall.sh --purge-codex` only if you also want to remove the standalone remote CLI installed by this project.

## Learn more

- [Quick testing guide](docs/testing.md)
- [How it works](docs/architecture.md)
- [Installation reference](docs/installation.md)
- [Commands and profiles](docs/usage.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Security and Apocrita policy](docs/security-and-policy.md)
- [Experimental Windows/WSL notes](docs/windows-wsl.md)

## Status

This is an independent project, not an official QMUL integration. Test it with an ordinary CPU profile before relying on it for important work.

Licensed under the [MIT License](LICENSE).
