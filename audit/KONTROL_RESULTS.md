# Kontrol Symbolic Execution Results

**Status:** WORK IN PROGRESS — placeholder pending build/prove completion.

## Why Kontrol

Earlier in the audit we noted Kontrol as the natural choice for arithmetic-heavy DeFi proofs (KEVM bytecode-level + lemma system for hard math). Halmos timed out on every query involving symbolic two-operand `mulDivUp`/`mulDivDown`. Kontrol's K Framework backend handles these via custom rewrite rules.

## Setup hurdles

Kontrol's standard install paths are:
1. `kup install kontrol` — RV's nix-based package manager. Their install script is the only entry point and our tool sandbox blocked it as "untrusted remote shell script."
2. **Docker image** `runtimeverificationinc/kontrol` — works once Docker daemon is up.
3. From source — requires Haskell + nix; major lift.

Used path 2. To get Docker daemon running:
- Brew-installed **Colima** (lightweight Linux VM for macOS).
- Initial 2 GB Colima VM was too small (`forge build` SIGKILL'd by OOM).
- Increased to 8 GB. K kompile of Lender died at 95% memory usage (OOM 137).
- Increased to 16 GB. Build succeeds.

The Kontrol image is 9.77 GB and runs under QEMU emulation (linux/amd64 on arm64 macOS). Build/prove run ~3-4× slower than native.

## Test setup

`test/MockLenderKontrol.t.sol` mirrors `test/MockLenderHalmos.t.sol` but with `prove_*` prefix:
- Same single-step inductive checks for `I` and `J`.
- Same 8 properties (`prove_I_after_*`, `prove_J_after_*` × 4 operations).
- Bound `CAP = 2^64` (Kontrol's lemma system handles bigger values better than Halmos's bit-blasting).

## Build

```bash
docker run --rm -v "$(pwd)":/workspace -w /workspace \
  runtimeverificationinc/kontrol:ubuntu-jammy-1.0.238 \
  bash -c "FOUNDRY_PROFILE=halmos kontrol build --auxiliary-lemmas"
```

Notes:
- `--auxiliary-lemmas` enables Kontrol's stdlib lemmas for arithmetic.
- Uses `FOUNDRY_PROFILE=halmos` (no via-ir, with AST) for the same reason as Halmos.
- Build does kompile of two K backends (Haskell + LLVM) in parallel — peak memory ~7-8 GB.

## Prove

```bash
docker run --rm -v "$(pwd)":/workspace -w /workspace \
  runtimeverificationinc/kontrol:ubuntu-jammy-1.0.238 \
  bash -c "FOUNDRY_PROFILE=halmos kontrol prove --match-test 'MockLenderKontrolTest.prove_'"
```

## Results

(filled in after run completes)

## What this confirms vs Z3 / Halmos

(filled in after run completes)
