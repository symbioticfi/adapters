# MerkleAccount Management Implementation Plan

> **For agentic workers:** Use executing-plans for implementation and independently scoped integration tasks in parallel.

**Goal:** Make the migratable account own strategy authorization and execution, while the adapter bridges vault assets and supplies oracle accounting.

**Architecture:** MerkleAdapter creates MerkleAccount through its migratable factory at `lastVersion()` and with `owner()`. The account stores roots, enumerable roles, capabilities and signature approvals. Account-authorized actions call adapter `push(amount)` or `pull(amount)` to move underlying without exposing reserves.

**Tech Stack:** Solidity 0.8.37, OpenZeppelin, Symbiotic MigratableEntity/MigratablesFactory, Foundry, TypeScript/Viem.

**Spec:** User request in this task: replace release with push/pull; initialize infinite account approval; migratable account with latest version and adapter owner; move capabilities, management and root into account.

## Global Constraints

- Contracts use `^0.8.28`; other Solidity files use their minimum language version.
- Follow CONTRIBUTING.md; use named struct initializers and OZ methods.
- No compatibility shims or legacy deployments.
- Preserve the existing generic signature hashing changes and unrelated dirty files.
- Do not commit or push as part of this request.

## Review Focus

- Pending allocations and matured withdrawals cannot be spent by push.
- Pull uses the account allowance, fixed paired addresses and account-only authorization.
- Latest-version creation and owner-authorized migration preserve strategy state.
- Merkle proofs and all caller roles are checked before any action executes.
- Frontend/backend must resolve the account before authorization, root and capability reads/writes.

## Contract ABI

```solidity
// MerkleAdapter implementation constructor:
constructor(address newVaultFactory, address newAdapterFactory, address newOracleFactory, address newAccountFactory);
// Existing adapter payload remains InitParams {address defaultAdminRoleHolder;}, passed through to account.
function push(uint256 amount) public; // adapter -> account, account-only, reserve checked
function pull(uint256 amount) public; // account -> adapter, account-only, safeTransferFrom
// MerkleAccount implementation constructor:
constructor(address newFactory, address newRootRegistry, address newCapabilitiesRegistry);
// Account initializer data:
IMerkleAccount.InitParams({adapter: address(this), defaultAdminRoleHolder: params.defaultAdminRoleHolder});
// Action type, manage, root acceptance, capability and role API move to IMerkleAccount.
// RecipeExecutor constructor becomes (newOwner,newAccount), getter account().
```

### Task 1: Contracts and authorization

Files: `src/contracts/MerkleAdapter.sol`, `src/contracts/merkle-adapter/MerkleAccount.sol`, corresponding interfaces, registries, Oracle and RecipeExecutor.

- [x] Add focused regression coverage for factory creation, account allowance, reserve-protected push and pull, account roles and migration.
- [x] Run focused tests and record the failing baseline before implementation.
- [x] Move authorization unchanged into account; execute direct calls after whole-batch verification; add migratable initialization and capability fallback from local mapping.
- [x] Create account through factory; replace release with push/pull; remove adapter strategy interfaces.
- [x] Route Oracle role checks and workflow acceptance through account; route RecipeExecutor through account.
- [x] Run Foundry non-fork suite and selected deployed CoW settlement tests.

### Task 2: Solidity integration and recipes

Files: `script/`, `test/`, snapshots (excluding independently owned new migration regression file).

- [x] Adapt deploy scripts to whitelist account implementation, use its latest version and configure account registries/roles.
- [x] Change recipes from release/transfer funding to adapter push/pull through account manage.
- [x] Update existing tests to the new authority without loosening authorization assertions.
- [x] Run non-fork suite and fix remaining integration failures.

### Task 3: Curator frontend

Files: Merkle chain queries, ABI declarations, catalog, transaction drafts, roles/strategy/automation UI and tests in the frontend worktree.

- [x] Add tests proving manage/root/capability/role writes target the account and funding targets the bridge inside manage.
- [x] Resolve account and account owner, use new factory/RecipeExecutor constructor and account registries.
- [x] Advance shared catalog to version 24; generate matching vectors with backend.
- [x] Run real-contract Anvil integration plus full `pnpm run check` with usable chain env.

### Task 4: Backend and NAV

Files: Merkle tree admission/resolution/catalog and NAV chain readers if applicable.

- [x] Read account owner for curator authority while retaining adapter route identity and reserve accounting.
- [x] Mirror version-24 catalog and fixtures; update readers and documentation.
- [x] Run backend full gate and NAV verification if changed.

### Task 5: Integration review

- [x] Search all repos for obsolete release/manage/role/root routing and stale account construction.
- [x] Review actual diffs, compare shared catalog and fixtures, verify migration/settlement/reserve tests.
- [x] Format, check diffs and report exact verification outcomes and remaining limitations.

## Verification results

- Foundry: 1,151 passed, 0 failed, 1 skipped; deployed CoW settlement fork: 7 passed.
- New account initialization, migration, ownership, Oracle authority and pull tests: 10 passed.
- Frontend: full check including SSG passed; separate Anvil recipe (10), simulation (25) and history (4) suites passed. Final wording edits validated separately.
- Backend: lint, format, typecheck, build, 461 unit tests and 148 integration tests passed.
- NAV: `make verify` passed; only architecture documentation required changes.
- Frontend/backend catalog v24 and all nine changed shared catalog files match, apart from their expected Zod import.
