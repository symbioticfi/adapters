# Production-compatible testnet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Run fresh testnet deployments through actual upstream protocol contracts and normal Merkle consumers.

**Architecture:** Pinned upstream sources compile under their own supported compiler/configuration. Script-only artifact loading deploys their real creation code and linked libraries. One manifest exports consumer configuration; ordinary readers value the resulting positions.

**Tech Stack:** Foundry/Solidity, Python standard library, Go NAV, TypeScript frontend.

**Spec:** docs/superpowers/specs/2026-10-28-production-compatible-testnet-design.md (approved by user).

## Global Constraints

- Preserve upstream financial logic, compiler settings, code-size/gas limits and pinned dependency identities.
- Use official Sepolia 3F; no request-specific permissions or weaker checks.
- Use shared multi-reserve Aave, EVC-linked Euler vaults and real Morpho Vault V2 allocation; borrowing belongs to Blue.
- Inventory remains independently metadata-selected and exact-commit-pinned. Assets floor, debts ceil; missing evidence fails closed.
- Preserve unrelated local edits. No public-chain broadcast is requested.

## Review Focus

- Mixed-decimal collateral/debt must use correct prices and rounding.
- Partial liquidity must constrain withdrawals rather than invent cash.
- Root/receipt success must not substitute for accepted oracle reports in a later block.
- Artifact mismatch or unresolved linking must stop before broadcasting.
- Unsupported issuer fixtures must remain visibly unsupported, never silently omitted from advertised coverage.

### Task 1: Pinned artifact build and deployment boundary

**Files:** Create script/deploy/testnet/upstream/{prepare.py,artifact.py,pins.json}; script/deploy/testnet/protocols/UpstreamArtifacts.sol; test/deploy/testnet/UpstreamArtifacts.t.sol; script/deploy/testnet/upstream/test_artifacts.py.
**Interfaces:** `_deployArtifact(string profile, string contractName, bytes constructorArgs) returns (address)` loads prepared creation code, recursively deploys/caches linked libraries and creates the contract. Python artifact CLI returns ABI `(bytes,string[],uint256[])` for zeroed code, library identifiers and byte offsets. Cache roots and source pins contain no credentials.

- [x] Write/run failing tests for linked bytecode, pin mismatch, invalid link length/offset and absent artifacts.
- [x] Implement minimal pinned preparation using subprocess/git/forge and standard-library JSON; compile each upstream independently, never rewrite source pragmas.
- [x] Verify real linked artifact deployment under normal limits; run Python/Foundry tests and commit scoped changes.

### Task 2: Production lending deployment helpers

**Files:** Create protocols/UpstreamAave.sol, protocols/UpstreamEuler.sol, protocols/UpstreamMorpho.sol; matching test/deploy/testnet/Upstream*.t.sol; update pinned descriptors from Task 1.
**Interfaces:** Helpers accept owner/broadcast plus assets/prices and return explicit addresses/configuration for real pools, factories, vaults, reserve IDs and underlying markets. Root integration consumes the returned structures; no financial behavior is implemented in these helpers.

- [x] Write/run failures asserting standard reserve/user reads, EVC ownership, canonical factory predicates, V2 allocation/caps and cross-asset borrowing.
- [x] Implement pinned upstream deployment and administrative configuration. Replace edited Blue/Midnight copies with artifacts.
- [x] Verify supply/borrow/accrue/repay/withdraw, insufficient collateral and cash limits, including 6/18 decimal pairs. Commit helpers and tests.

### Task 3: Full scripts, seed/activity and configuration export

**Files:** Modify DeployRealisticTestnet.s.sol, SeedRealisticTestnet.s.sol, ValidateRealisticTestnet.s.sol, activity/MerkleMarketActivity.s.sol, activity/MarketActivity.s.sol and existing manifest consumers; create export_config.py and tests. Remove unused model code after callers migrate. Touch only own hunks in pre-existing dirty Python helpers.
**Interfaces:** Deployment manifest contains canonical protocol facts and pinned upstream artifact identity. `export_config.py MANIFEST --out DIR` writes public frontend/NAV profiles and adapter inventory metadata; no balances or private RPC/key material.

- [x] Run a failing full deploy/seed/activity test against the upstream helpers.
- [x] Wire the shared market topology and real APIs throughout. Morpho V2 only supplies/withdraws; Blue handles borrow/collateral.
- [x] Export complete selected deployment/inventory/feed facts. Keep and publish an admitted integration compatibility matrix.
- [x] Run the full sequence on disposable Anvil and verify canonical contracts, balances, debt, approvals and exact receipts. Commit scoped changes.

### Task 4: Normal NAV readers for configured deployments

**Files:** NAV internal/client/{metadata,lending,morpho,threef,prices,holdings}, internal/usecase/valuation/{live,testnet,service}.go, cmd/navd and configuration docs/tests as required. Remove internal/client/testnet and TestnetSnapshot only after equivalent ordinary-reader acceptance passes.
**Interfaces:** The exported manifest profile configures the normal reader construction and report chain ID; adapter-bound inventory metadata remains independently required.

- [x] Baseline `make verify` before edits; state each reader's read cost before writing.
- [x] Write/run failures for Sepolia chain/profile isolation, requested catalogue addresses, baselines and report chain ID.
- [x] Inject validated facts at normal construction boundaries, preserving complete snapshots, accounting and receiver witnesses.
- [x] Read full deployed positions through normal collectors at one pinned block; compare exact balances/debt and measure physical reads. Run `make verify`, update budget/coverage docs and commit.

### Task 5: Frontend simplification and end-to-end parity

**Files:** frontend deployments/sepolia/merkle.json, shared/config/merkle.ts, portfolio deployment/metadata hooks and venue-label provider/callers; related tests/docs.
**Interfaces:** Generated public profile feeds existing normal readers/builders. Proper metadata names eliminate label rewrite compatibility code; compact 3F previews remain.

- [x] Write/run failures proving generated configuration works and no stale builtin deployment or model-name override is needed.
- [x] Remove redundant special cases and consume the generated deployment facts.
- [x] Read the same deployed portfolio/block as Task 4; compare exact positions and values. Run `pnpm run check` and fresh build budgets; retain the established wallet-preload failure if unchanged, without raising ceilings.
- [x] Final independent review, fix important findings with red/green tests, push scoped PRs and report source/deployment/live-test boundaries.
