# Merkle funding capacity implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement the tasks inline.

**Goal:** Quote LL and 3F funding available inside a MerkleAccount, including reviewed synchronous withdrawal sources.

**Architecture:** A stateless `MerkleFundingLens.getAvailableAssets(account, asset, sources)` adds account cash to configured scalar capacity queries. Consumers cap this funding by the existing connector or policy budget. Operator configuration must match the actual approved recipe, use disjoint sources and include any health floor in the capacity query. A configured read failure propagates; an absent configuration retains conservative cash-only sizing.

**Tech stack:** Solidity 0.8.37 / Foundry 1.8.5, TypeScript / viem, Go / generated ABI bindings.

**Spec:** User-approved shared funding calculation in this conversation, 2026-10-26.

## Global constraints

- Keep Core and account execution permissions unchanged.
- All reads in one capacity observation use the same block.
- Exclude NAV, staged adapter cash and future/asynchronous liquidity.
- Reject duplicate sources and malformed responses; capacity is an estimate and execution must still be simulated.
- Do not configure undeployed addresses or deploy contracts as part of this task.

## Review focus

- Duplicate and overlapping positions must not inflate capacity: reject duplicate source identities and document disjoint configuration.
- Failed or short capacity replies fail closed, including nonzero return-word offsets.
- Funding configuration for one account/asset must never apply to another.
- LL uses output-asset units and 3F uses request-funding units; budget and live reservations still apply.
- Unconfigured consumers preserve cash-only behavior; configured failures must not fall back.

## Task 1: Shared stateless lens

- [x] Add Foundry tests for cash, source amounts, offsets, malformed replies, duplicates and budget-independent funding.
- [x] Observe the tests failing before implementing the new lens/interface.
- [x] Add `src/contracts/merkle-adapter/automations/liquidity/MerkleFundingLens.sol` and its corresponding interface.
- [x] Run the relevant tests and full local Foundry suite; document API/configuration limitations.

## Task 2: RFQ backend (new PR stacked on #430)

- [x] Add a bounded, validated account/asset funding-source configuration and tests.
- [x] Test connector publication/listing/quote capacity above cash, budget capping and pinned failure behavior.
- [x] Call the shared lens at the existing observation block, preserving standalone adapter behavior.
- [x] Run `pnpm check`.

## Task 3: Solver consumers (new PR stacked on #221)

- [x] Generate a binding from the lens artifact and add a shared configured funding reader.
- [x] Test account/asset routing, block pinning, errors, cash-only defaults and capacity beyond cash.
- [x] Use it in RFQ pricing and 3F offers, keeping existing budgets and reservation subtraction.
- [x] Update operator documentation; run Go tests, build and lint.

Delivery: open the adapters PR against codex/bailsec-normalized, the RFQ PR against
codex/merkle-connector-discounts (#430), and the solver PR against
codex/merkle-sdk-integration (#221). Deployment/source activation remains operator work.
