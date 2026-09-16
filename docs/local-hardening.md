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

| Mode | Time |
|---|---|
| full (`harden.sh`) | ~59 min |
| fast (`harden.sh -f`) | ~6 min |

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

## Why more cores don't always help

LibreLane already defaults to every core (`OPENROAD_THREADS` unset means all
64 here). The long steps are Magic (`magic-drc`, `magic-writelef`,
`magic-streamout`), which are single-threaded: `magic-drc` measured 455s of
user CPU against 0s of system time, so it is genuinely compute-bound rather
than paying proot overhead. `-j` is there to be a good neighbour on a shared
machine, not to go faster; `-f` is what actually shortens the loop.
