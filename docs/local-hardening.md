# Local hardening

Run the full RTL-to-GDS flow on this machine instead of waiting on the `gds`
workflow. Same LibreLane version as CI (`3.1.0.dev3`), same config, same PDK.

```sh
./scripts/harden.sh          # full flow, everything CI checks
./scripts/harden.sh -f       # fast: skip Magic DRC
./scripts/harden.sh -j 16    # cap threads -- this is a shared machine
```

It shows a progress bar (steps done / 72, current step, elapsed, ETA) and
prints the key metrics at the end. Results land in `runs/wokwi/`.

**Use `-f` while iterating.** Magic DRC is roughly 80% of the runtime and is
checking the PDK rules, which RTL edits cannot break in new ways from one run
to the next. Measured on this machine:

| Mode | Near-empty die | Real logic at 24% utilisation |
|---|---|---|
| full (`harden.sh`) | ~59 min | dominated by routing, see below |
| fast (`harden.sh -f`) | ~6 min | detailed routing alone ran past 50 min |

**Those first-column numbers were measured on the Tiny Tapeout example and do
not carry over.** With real logic the bottleneck moves from Magic DRC to
detailed routing, which under proot is slow enough that CI is the better place
for a full run. Use the local flow for lint, tests, proofs and area; use `-f`
locally when you want to see placement and routing actually converge; let CI
produce the numbers you quote.

The `gds` workflow always runs the full flow, so nothing reaches a submission
without Magic DRC having passed. A full local run reproduces CI's numbers
exactly -- same die area, same setup and hold slack to four decimal places,
same zero violation counts.

## How the environment works

The box is Rocky 8 with no root, no Docker/Podman and no system Nix. LibreLane
is a Nix-native project, so the environment is LibreLane's own Nix closure run
through **nix-portable** (a single static binary giving rootless Nix).

| Piece | Location |
|---|---|
| nix-portable binary | `~/eda/nix-portable` |
| Nix store | `~/eda/.nix-portable/nix/store` (~4.3 GB) |
| GC root for the LibreLane env | `~/eda/librelane-env` |
| IHP CMOS5L PDK | `~/eda/pdk` (pinned to the rev `tt-gds-action` uses) |
| `tt_tool.py` Python deps | `~/eda/lrvenv` |
| `tt-support-tools` checkout | `./tt` (gitignored) |

## Three traps, each of which cost real time

**1. Use LibreLane's binary cache, or Nix compiles everything from source.**
The tools live in `https://nix-cache.fossi-foundation.org`, not
`cache.nixos.org`. Without it, Nix silently starts building OpenROAD, Yosys
and KLayout from source — an hour or more and several GB of build-only junk.
The cache and key come from LibreLane's installation docs:

```
extra-substituters        = https://nix-cache.fossi-foundation.org
extra-trusted-public-keys = nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=
```

**2. Use the proot runtime, not bwrap.** nix-portable defaults to bubblewrap,
which already runs inside a user namespace, so Nix's own attempt to create a
private mount namespace fails with
`setting up a private mount namespace: Operation not permitted`.
`NP_RUNTIME=proot` avoids namespaces entirely. `--option sandbox false` alone
does **not** fix it.

**3. Keep the GC root.** Nix garbage collection deletes anything not reachable
from a root, and `nix run` does not create one. `~/eda/librelane-env` is the
root that keeps the ~4 GB LibreLane closure alive. Never delete that symlink
before a GC.

## Rebuilding the environment from scratch

```sh
export NP_LOCATION=$HOME/eda NP_RUNTIME=proot
~/eda/nix-portable nix build \
  --extra-experimental-features "nix-command flakes" --option sandbox false \
  --option extra-substituters "https://nix-cache.fossi-foundation.org" \
  --option extra-trusted-public-keys "nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=" \
  --out-link ~/eda/librelane-env github:librelane/librelane/3.1.0.dev3
```

Bump the tag in lockstep with `librelane-version` in `tt-gds-action`, or local
and CI results will diverge.

## Why more cores make it slower, not faster

The whole flow runs under **proot**, which supervises the sandboxed processes
with `ptrace`. That supervision is a single process, and every syscall from
every thread inside the sandbox funnels through it. It saturates one core on
its own and becomes the ceiling for the entire run.

Measured on this machine, on the same design:

| `OPENROAD_THREADS` | Global placement |
|---|---|
| unset (LibreLane default) | ~2 min |
| 32 | still unfinished after 30 min |

In the second case OpenROAD held 64 threads at a combined 150% CPU while proot
sat pegged at 95% of a single core: more threads meant more syscall traffic
through the one process that could not go any faster.

`-j` is therefore opt-in and off by default. It exists to *reduce* thread
count on a busy shared machine, not to raise it. `-f` is what actually
shortens the loop.

This is also why a local run is roughly 3x slower than the same flow in CI
despite the machine being far larger. Two earlier readings of this are worth
correcting, because both were wrong:

- LibreLane does **not** already use every core. Left unset, it passes the
  literal string `None` through, and OpenROAD answers
  `[WARNING ORD-0032] Invalid thread number specification: None` and drops to
  one thread for the steps that honour the setting.
- The slow steps are **not** simply compute-bound. `magic-drc` showing user CPU
  but no system time proves nothing here: under `ptrace` the syscall time is
  charged to proot, not to the traced process.

For a routing-heavy design, CI remains the faster full run as well as the
authoritative one.
