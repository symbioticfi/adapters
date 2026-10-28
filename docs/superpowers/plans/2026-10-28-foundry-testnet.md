# Foundry-native testnet implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Remove custom Python deployment/broadcast orchestration without losing speed or recovery.
**Architecture:** Independent existing Foundry phase scripts, a thin shell launcher, native signed artifacts and resume. Host helpers retain upstream compilation/config export and randomized test activity.
**Tech Stack:** Foundry 1.8.5, Solidity 0.8.37, Bash, Python standard library.
**Spec:** docs/superpowers/specs/2026-10-28-foundry-testnet-design.md

## Global constraints

- No public-chain broadcasts, signing secrets in output or changed chain limits.
- Preserve existing phase behavior and ordinary NAV daemon reporting.
- No deployment `--slow`, custom gas replay, signed-artifact conversion or legacy aliases.
- Existing upstream pin/build and metadata configuration remain unchanged.

## Review focus

- Resume must preserve CREATE destinations, successful receipts and exact pending transactions.
- A second fresh run must not overwrite an existing manifest.
- Keystore signing must work without private-key export, including local ownership proofs.
- Pin/owner/chain mismatch and insufficient seed backing must fail before transactions.
- Large dependent deployments must fit actual gas limits and stay batched.

### Task 1: Foundry phase guards and signing

**Files:** ActivateMerkleTestnet.s.sol, DeployRealisticTestnet.s.sol, base/TestnetPhase.s.sol, SyncMerkleTestnet.s.sol, corresponding test/deploy/testnet suites.
**Interfaces:** Existing phase `run()`/`runBase()` and TESTNET_MANIFEST/OWNER env. Foundry's loaded wallet supplies `vm.sign(address,bytes32)`.

- [x] Add and run failing tests for direct wallet signing, wrong pins/owner/chain and manifest overwrite.
- [x] Move required guards/signing into existing phase scripts; run focused Foundry tests.

### Task 2: Remove Python deployment orchestration

**Files:** run.sh, bootstrap.py, fast_broadcast.py and their tests; actions.py/runtime.py; README.md.
**Interfaces:** `run.sh deploy|activate|sync|seed|validate [forge flags]`, TESTNET_RPC_URL, TESTNET_OWNER, TESTNET_MANIFEST. Existing upstream prepare/export remain.

- [x] Exercise native batched broadcast and interrupted resume on a disposable node.
- [x] Delete custom planner/bootstrap, retain only activity host helpers, update every current caller/documentation and run Python suites.

### Task 3: Complete environment rehearsal and publication

**Files:** opt-in native Foundry integration test and local ignored evidence.
**Interfaces:** Exact original Foundry artifacts, ordinary NAV profiles/daemon, canonical manifest.

- [x] Deploy all contracts locally with native Foundry; record timing/receipt counts and recover an interruption.
- [x] Activate, publish ordinary reports, seed, sync and validate; run full contract/Python/format gates.
- [x] One independent whole-diff review, fix important findings with regression tests, update signed PR #11.
