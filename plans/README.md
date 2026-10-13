# Recipe builder advisory review

Historical planning review on 2026-10-13 against HEAD `c925f8236e0d4768832d85cc5a5ffef4aa369675`: [recipe-second-followup-review.md](recipe-second-followup-review.md). No new recipe correctness/security defect was confirmed. The user selected O08–O10 for separate implementation plans 008–010; O11 remains unselected. That review performed no implementation, new Solidity regression run or gas measurement; the selection at that time requested planning only.

| Finding | Opportunity                                                               | Recommendation                                                                                                 | Status                                                                                                         |
| ------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| O08     | Use selected amounts for progress in qualifying multi-output claim groups | Normal −1 instruction; eight-output −7; gas514,547→510,732                                                     | DONE as 008                                                                                                    |
| O09     | Omit capped identity-rate multiplication only with an overflow proof      | Bounded claim −1, health claim −2 instructions; gas 149,212→145,223 / 639,433→631,377; uncapped controls equal | DONE as 009                                                                                                    |
| O10     | Omit signing price positivity implied by the positive output floor        | CoW 15→14, Liquid Lane 14→13; −160 bytes each; gas 189,236→185,734 / 193,686→190,136                           | DONE locally as 010; 22 signing, 234 integrated, 2,246 full and 18 invariant tests pass; 4 optional full skips |
| O11     | Omit cached-producer opcode lookup implied by initialized State           | Optional experiment; retain only with exact ABI and gas nonregression                                          | Unselected                                                                                                     |

O08/O09 overlap ClaimRecipe but are logically independent; execute 008 then 009, capturing a new baseline after a verified retention or rejection of 008. O10 is independent and runs last in the selected batch. At planning time, size reductions were projections and gas was unmeasured; the current rows above record retained measured results. All three plans preserve separate logical changes and require frozen before/after execution fixtures. The existing scope helper now supports their exact dirty-baseline scopes and gas acceptance policies, including unchanged uncapped controls for 009. No execution baseline or new benchmark measurements were created during planning.

Planning validation for 008–010: all eighteen shell blocks parse; helper syntax and 31 independent in-memory gas acceptance/rejection cases pass, and every previous scope/gas policy remains unchanged. A fresh-context read-only reviewer verified source pins, predicates, fixture accounting, signature-aware selectors, snapshot boundaries and generated-output scopes, with no remaining required corrections. At that planning checkpoint, the three recipe source hashes matched the planning baseline and no source/test/manifest/snapshot implementation, Foundry suite, gas benchmark, commit or publication had been performed.

Current implementation: plans 008 and 009 are verified and committed locally as `321802b` and `a9a2896`. Plan 008 reduces its frozen claim execution by 3,815 gas; Plan 009 reduces the bounded claim and health claim by 3,989 and 8,056 gas while both uncapped controls remain exactly equal. Plan 010 passes fresh cumulative RED/GREEN and strict CoW/Liquid Lane gas gates (3,502 and 3,550 lower) after 009 with the same frozen test source. The final combined local run passes 2,246 tests across 149 suites with 0 failures and 4 known optional skips; invariants pass 18 across 6 suites with no failures/skips, signing passes 22, prescribed export scope 94 and expanded Claims/Recovery/Signing integration 234. Build, formatting, aggregate snapshots, frozen hashes, scope and all twelve generated-output preservation gates pass. Fresh whole-batch review reports PASS with no actionable findings and matching reviewed hashes. The controller separately reports 166 focused tests and six isolated gas fixtures passing in the original checkout with all six final labels matching. These local results establish no publication, deployment or live-chain adoption.

Considered and rejected/deferred in this review: uncapped identity cancellation, removal of signing's positive floor, deadline/slippage substitutions, generic stale-read reuse, and removal of accounting/allowance checks. The smaller opcode-filter experiment for the existing offchain builder-scan investigation remains deferred without measured build-time benefit. O06/O07 remain rejected. Full evidence, bounds, prior-candidate reconciliation and verification limits are recorded in the new report.

Additional read-only optimization review on 2026-10-12 against current HEAD `901c82c`: [recipe-optimization-review.md](recipe-optimization-review.md). The user selected plans for O01-O03; source and snapshots remain unchanged by the advisory work.

Further review after implementing O01–O03: [recipe-followup-review.md](recipe-followup-review.md). No additional correctness defect was confirmed. O04 is a new lending positivity reduction; O05 reconfirms the initial recovery clamp reduction; O06/O07 are previously noted runtime benchmark candidates. The user selected all four findings for plans 004–007. The user authorized implementation with one separate unsigned local commit per plan, after a prerequisite recipe commit on the current branch. Plans 004 and 005 are verified; Plan006 was rejected after a capability gas regression and its production files were restored. Plan007 also reached REJECTED after gas/ABI gates; both runtime candidates are restored.

The follow-up report records rejected candidates, including the absence of reversed-operand matches in the eleven current manifests, unsafe generic caching/health-bound propagation, and behavior changes from unchecked arithmetic or early Manage gates. Existing plans 001–003 remain DONE; the first optimization report is a historical pre-implementation review.

## Optimization implementation plans

Execute in the order below. All plans include the current dirty/untracked working-tree baseline, failing-first structural regressions, semantic tests, gas measurements, artifact gates and stop conditions. Planning does not itself request implementation or publication.

| Plan                                           | Finding | Title                                               | Priority | Effort | Depends on                                    | Status   |
| ---------------------------------------------- | ------- | --------------------------------------------------- | -------- | ------ | --------------------------------------------- | -------- |
| [001](001-claim-progress-maxima.md)            | O02     | Track standalone claim progress with maxima         | P2       | S      | None                                          | DONE     |
| [002](002-implied-positivity-guards.md)        | O03     | Omit positivity guards implied by output floors     | P2       | S      | 001 for cumulative claim baseline             | DONE     |
| [003](003-recovery-cash-snapshots.md)          | O01     | Carry conditional recovery cash snapshots           | P2       | M      | Independent; run after 002                    | DONE     |
| [004](004-lending-implied-positivity.md)       | O04     | Omit lending positivity implied by its minimum      | P2       | S      | Current completed baseline                    | DONE     |
| [005](005-initial-recovery-health-clamp.md)    | O05     | Omit the initial recovery health clamp              | P2       | S      | Independent; run after 004                    | DONE     |
| [006](006-decode-executor-steps-once.md)       | O06     | Decode executor steps once if benchmarks improve    | P2       | S      | 004 and 005 DONE                              | REJECTED |
| [007](007-selective-return-data-copies.md)     | O07     | Copy selected return data if real workloads improve | P3       | M      | 004/005 DONE; 006 DONE or verified REJECTED   | REJECTED |
| [008](008-claim-progress-witnesses.md)         | O08     | Use selected amounts for qualifying claim progress  | P2       | S      | Current completed baseline                    | DONE     |
| [009](009-capped-identity-rates.md)            | O09     | Omit cap-proven identity-rate calculations          | P2       | S      | 008 DONE or verified REJECTED, fresh baseline | DONE     |
| [010](010-signing-implied-price-positivity.md) | O10     | Omit signing price positivity implied by its floor  | P2       | S      | Independent; run after 009                    | DONE     |

Execute the selected new batch serially: 008 → 009 → 010. Plan008 preserves all twelve saved catalogue outputs. Plan009 changes only the two capped claim manifests, retains both uncapped gas controls exactly and keeps unsafe/uncapped products checked. Plan010 preserves all saved outputs and exact signing authorization bytes. Each candidate has failing-first structural targets, semantic/rollback checks and strictly improving frozen representative gas fixtures; rejected candidates must be restored and documented.

The completed earlier batch ran serially: 004 → 005 → 006 → 007. Plans 004/005 each require a failing-first structural target, preserved semantic behavior, a 160-byte reduction and strictly improved frozen gas fixtures. Plan005 explicitly updates only the intentional recovery hash/count/length pins from O01 and keeps claim/repay behavior unchanged. Both builder plans regenerate only their affected manifests.

Plans 006/007 freeze post-builder workloads and require same-context differential results, exact revert bytes, unchanged public ABI and byte-identical saved manifests. Plan006 requires all seven measured executor template workloads to improve and all fourteen measurements to be nonregressing. Plan007 requires all twenty-one measurements to be nonregressing and at least one representative recipe workload to improve; synthetic large-return gains alone do not qualify. Unprofitable runtime changes must be restored and marked REJECTED with evidence, rather than retained as successful refactors. Plan007 can proceed after a verified Plan006 rejection using the restored production baseline.

The earlier planning batch extended the scope helper through plans 004–007, byte-for-byte generated-output checks and executable gas acceptance checks. The 2026-10-13 additions now extend its scopes through 010. It still requires a fresh dirty-baseline snapshot at the start of each authorized implementation. No implementation baseline copies or benchmark results were created by either planning turn.

Planning validation: all four plans' shell blocks parse; the helper's Python syntax and in-memory passing/rejection scenarios pass, including unchanged controls, per-workload regressions and synthetic-only gains. A fresh read-only reviewer verified the source pins, suite/label names, dirty scopes and rejection paths and found no remaining actionable plan issues. The five relevant production source hashes still match the planning baseline. No source implementation, new Foundry regression run, gas measurement, commit or publication was performed.

Implemented locally on 2026-10-12 using pinned Foundry 1.8.1. O02 + O03 reduce the standalone claim fixture from 554,023 to 514,494 gas. O03 reduces health-claim from 622,460 to 607,533 and LL from 871,863 to 868,316 gas. O01 reduces the conditional two-source, two-claim and one-active-group fixtures from 1,143,626 to 1,128,070; 628,597 to 613,177; and 773,015 to 760,067 gas. Two-group cash reads fall from six to three before approval, and ABI encoding shrinks by 512 bytes.

All 2,154 executed local and invariant tests pass, with four existing optional skips. Build, snapshots, saved catalogues, formatting and scope gates pass. Plans record detailed evidence and limitations. A fresh read-only review found no actionable issues. Changes remain uncommitted and unpublished.

Plan002 follows Plan001 because both modify ClaimRecipe: the one-output claim examples lose one instruction through O02 and two more through O03. Absolute counts must be captured from the live bounded-claim/conditional-read baseline. Plan003 is independent but runs last in the first batch because it shares RecoveryRecipe with Plan002 and completes that batch's broader serial validation. Runtime decoder/copying candidates are now selected as plans 006/007; general range inference and guarded 3F input compaction remain unselected. Conditional standalone-claim output reads were added by concurrent work and are now preserved by the plans. Existing false-option example manifests stayed unchanged during Plan003; its new commitments belong only to true-option builds. Plan005 intentionally changes recovery encodings in both modes.

Each plan uses [recipe_plan_checks.py](recipe_plan_checks.py) for an executable dirty-baseline snapshot, generated-artifact preservation and scope gate. Execution must first pass the existing saved-catalogue check; stale or missing manifests from other ongoing work are a baseline stop condition. A fresh read-only reviewer checked arithmetic, read counts and rollback requirements; the plans explicitly preserve the no-progress claim revert.

Reviewed on 2026-10-12 using the `improve` skill, deep effort, scoped to the Solidity recipe builder in this repository.

- Repository: `/Users/andreikorokhov/symbiotic/adapters`
- Branch: `codex/merkle-staging-forwarder`
- HEAD: `2b9868f1d06ce61adadc94a489a2938ef3b6f285`
- Working tree: pre-existing ThreeFPolicy and testnet deployment changes were present. The review used the current files and left them unchanged. No recipe-builder source or tests were edited.
- Status: F01 is fixed and verified locally with three new regression tests. D01 and D02 remain unselected. The audit observations below describe the pre-fix source.

## Scope and verification

Reviewed all eight Solidity files under `script/recipes`, their examples and generated fixtures, recipe interfaces, interpreter/executor/capability consumers, and relevant account authorization, tests, documentation, and CI configuration. The passes covered correctness, security boundaries, performance, test coverage, architecture, dependency/configuration consistency, tooling, documentation, and grounded product direction.

The repository builds Solidity 0.8.37 with via-IR, optimizer 200, Osaka, and no bytecode metadata hash. It pins Foundry 1.8.1 and pnpm 11.25.0. The local executable was Foundry 1.8.5; no toolchain installation was performed.

Executed:

```sh
UPDATE_RECIPE_MANIFESTS=false forge test --offline \
  --match-path 'test/adapters/merkle-adapter/Recipe*.t.sol' \
  --no-match-contract '.*(Mainnet|Benchmark).*' \
  --gas-snapshot-emit false --gas-snapshot-check false --threads 2
```

Result: **319 passed, 0 failed, 0 skipped across 19 suites**. Compilation used Solidity 0.8.37. Snapshot emission and fixture regeneration were disabled; generated compiler/test files stayed under ignored output/cache directories. The pre-existing tracked/untracked source status was unchanged after this command. Existing green tests do not reproduce the newly identified missing scenario below.

Not audited or verified: sibling Curator frontend or Go executor implementations; deployed chain state, wallets, permissions, and transactions; the complete adapter/oracle system; full dependency vulnerability advisories; hosted CI; mainnet fork and benchmark execution; full-repository test/format gates. No production exploit or deployed impact is claimed.

## Vetted findings

| ID  | Finding                                                                             | Category                    | Impact                                                                              | Effort                                | Fix risk                                           | Confidence                                     | Evidence                                                                     | Status       |
| --- | ----------------------------------------------------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------- | -------------------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------- | ------------ |
| F01 | Subtract pending recovery obligations before applying the per-execution request cap | Correctness / test coverage | Recovery stops requesting liquidity while uncovered need and issuer capacity remain | S, including focused regression tests | Medium: changes request sizing and committed bytes | High; regression failures reproduced and fixed | `script/recipes/RecoveryRecipe.sol:136`; `docs/HEALTH-RECOVERY-RECIPE.md:74` | DONE locally |

### F01 evidence and impact

`RecoveryRecipe.recovery` first limits the fresh target need by the remaining execution budget, then subtracts all existing pending redemptions:

```text
current:  newRequestGap = max(min(needAfterRepay, remainingBudget) - pending, 0)
intended: newRequestGap = min(max(needAfterRepay - pending, 0), remainingBudget)
```

The documented contract is a cap on newly funded recovery per execution, with existing pending principal deducted from the full unmet need. It is not a cap on aggregate outstanding requests (`docs/HEALTH-RECOVERY-RECIPE.md:10`, `:74`, `:88`).

A concrete construction using the existing `RecipeRecoveryTest` fixture:

- Debt is 300 USDC, health is 1.00, target health is 1.50: full repayment need is 100 USDC.
- Set the per-execution cap to 40 USDC and both immediate cash-source capacities to zero.
- The first execution queues 40 USDC from issuer A. The debt and health remain unchanged because requesting redemption is not repayment.
- Issuer B still has 100 USDC of capacity and sufficient RWA inventory, but the second run computes `max(min(100, 40) - 40, 0) = 0`.
- The final positive-progress assertion reverts, although 60 USDC remains uncovered and the second run could request 40 USDC within its cap.

Fixture evidence: `test/adapters/merkle-adapter/RecipeRecovery.t.sol:55`, `:62`, `:546`. Existing pending tests at `:196` and `:207` use a need equal to the default cap; smaller-cap tests at `:254` and `:263` do not combine that cap with pending obligations from prior runs. The specific two-run scenario was established by source analysis, not by adding or executing a new regression test.

Fix sketch: subtract total pending from the fresh post-repayment need, then cap the uncovered amount by the remaining per-execution budget. Preserve conditional-read behavior, the shared cap on new repayment plus new requests, complete pending deduplication, partial progress, and the no-progress rejection when pending truly covers all need. Add consecutive-run and seeded-pending regressions with conditional-read optimization both enabled and disabled; include fully covered pending and partial fresh repayment cases.

Deployment implication: fixing the builder does not alter already committed recipes. Affected recipes need rebuilding and curator publication of their new commitment; this review does not authorize or perform those actions. See `docs/RECIPE-EXECUTOR.md:387`.

## Optional direction

These are product choices, not defects or missing guarantees in the current implementation. Estimates are coarse.

| ID  | Option                                                          | Value and evidence                                                                                                                                                                                                                                                                                              | Effort           | Risk                                                                                             | Confidence     | Status                       |
| --- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------ | -------------- | ---------------------------- |
| D01 | Add a separate deployment preflight command for saved artifacts | Catch wrong account/adapter identities, unsupported executor/capability versions, and unavailable permissions before configuration. The manifest already exports required opcodes but deliberately does not verify deployments: `script/recipes/RecipeManifest.sol:118`, `docs/RECIPE-EXECUTOR.md:294`, `:350`. | M–L design/spike | Medium: must distinguish verified, unsupported, and unknown instead of overstating compatibility | High grounding | Optional, awaiting selection |
| D02 | Provide verified issuer query profiles for recovery             | Replace repeated manual unit normalization and request-accounting setup with one supported, fork-tested issuer profile. The current sample queries explicitly require issuer-specific replacement: `script/recipes/RecoveryRecipe.sol:23`, `docs/HEALTH-RECOVERY-RECIPE.md:115`.                                | L design/spike   | Medium: amount-based, request-ID, and epoch-based settlement must remain distinct                | High grounding | Optional, awaiting selection |

D01 should consume exact saved bytes and a pinned RPC block without changing renderer semantics. Its spike should establish trustworthy code-version and permission evidence before defining what it can mark verified.

D02 should start with one explicitly selected issuer and define capacity, pending, claimable principal, units, ownership, and binding rules. The repository's strategy documentation distinguishes amount-based claims from request-ID and epoch-based routes (`docs/MERKLE-AUTOMATION-STRATEGIES.md:401`); that distinction needs live verification when a profile is selected.

## Recommended order and dependencies

1. Select F01 first. Its characterization/regression test should fail on the current formula before the builder changes.
2. D01 is independent and optional.
3. D02 should use the corrected recovery behavior from F01 before validating an issuer profile end to end; it does not require D01.

The user requested direct implementation of F01. No plans or implementation work were requested for D01 or D02.

## Considered and rejected

- **Optimizer suppresses runtime failures:** `_resolved` and `_reuse` preserve the earlier mandatory operations proving operand validity; malformed earlier operations still fail first. Reviewed `script/recipes/ExecutingRecipe.sol:457` and `:470`, and differential tests in `test/adapters/merkle-adapter/RecipeOptimization.t.sol:461`. No additional defect confirmed.
- **Raw/helper runtime-slot mismatch:** both construction styles advance the same counter at `script/recipes/ExecutingRecipe.sol:294`; `Call` intentionally consumes no runtime payload. Ordering tests cover the distinction.
- **Unsafe automatic caching of generic reads:** generic reads remain fresh, standard ERC20 balance reuse stops at action barriers, and explicit tuple reads retain only the latest producer. These are documented boundaries, not defects.
- **Quadratic optimizer scans:** present in offchain construction, but no material bottleneck was established for current templates. A performance rewrite is not justified by this review.
- **Inspection proves deployment compatibility or historic provenance:** it does not claim either. Its scope is explicitly documented at `docs/RECIPE-EXECUTOR.md:294` and `:334`; D01 is a separate optional extension.
- **Trailing payload bytes and ignored operand bits:** inspection preserves these deliberately to match runtime semantics; covered by `test/adapters/merkle-adapter/RecipeInspect.t.sol:180`.
- **Manifest, nested-leaf, or runtime-slot drift:** exact recipe/hash/calldata checks, generated guarded-leaf checks, all-opcode fixtures, catalogue drift tests, and overwrite cleanup exist. No discrepancy found in current source or local tests.
- **Unused optimization options serialized in metadata:** applicability is template-dependent and explicitly tested at `test/adapters/merkle-adapter/RecipeBuild.t.sol:73`. Not treated as a bug.
- **Loose optional JSON collection parsing:** no concrete harmful input/use case was established. Do not promote `_length` shape permissiveness alone into a security finding.
- **Partial repayment, retained claim surplus, and executor/account call origins:** these are documented strategy and authorization choices. They must be preserved by future plans.

## Verification gates for selected plans

The focused read-only command above is the immediate regression baseline. An executor should use pinned Foundry 1.8.1 for final validation and follow the repository's current contribution rules. Broader gates include `forge build`, `forge test --no-match-contract '.*(Mainnet|Benchmark).*'`, and `forge fmt --check`. Required snapshot and example-fixture regeneration belongs to implementation, followed by review of the resulting diffs. Any live fork test needs an explicitly identified protocol, block, and archive-capable RPC; this audit did not run one.

## F01 implementation follow-up

The builder now subtracts all pending principal from the full post-repayment need, then caps new requests by the remaining execution budget. Conditional pending reads retain the old `min(need, remainingBudget)` gate, so exhausted budgets do not introduce unnecessary issuer reads.

Three new tests in `RecipeRecovery.t.sol` exercise the real recipe executor/account with the existing protocol fixtures and fuzz conditional reads on/off:

- Repeated 40-USDC-capped runs queue 40, 40, then 20 USDC toward a 100-USDC need, and a subsequent run rejects duplicate coverage.
- A 40-USDC cap with 90 USDC already pending requests only the remaining 10 USDC.
- A 60-USDC cap with 20 USDC already pending can repay 50 USDC from fresh cash and request another 10 USDC.

All three failed on the original implementation: two with `CheckFailed`, one because no new request was created. After the fix, all 45 recovery tests passed, including 100 fuzz cases for each new test. Validation uses the already installed pinned Foundry 1.8.1 and Solidity 0.8.37. The generated health-recovery manifest was refreshed; the other generated example files remained unchanged after formatting. An independent read-only review found no actionable issues. The serial snapshot-profile run passed 2,014 tests with four skips; the separate invariant run passed all 18 tests. All 2,032 executed tests passed. Recovery gas snapshots were regenerated with the pinned toolchain: the fully funded conditional path rises from 747,456 to 751,331 gas because preserving the read gate requires an additional numerical instruction; the unconditional and ordinary recovery labels are unchanged. The aggregate gas report was regenerated from the complete current working tree, so its diff also reflects pre-existing testnet and ThreeF work. No pre-existing source edits or ThreeF snapshot edits were overwritten.

The initial four-thread run passed 2,030 tests and skipped four, but these two activity tests failed after a shared `TESTNET_MANIFEST` environment variable pointed at another test's removed fixture:

- `ActivityIntegrationTest.test_All53ProfilesRunAfterMaturityAndPersistCursors`
- `ActivityIntegrationTest.test_ThreeFFinalizesAndConsumesNewSignedFundedRequests`

All eight activity-suite tests passed on a serial retry, followed by the complete serial validation above. This unrelated fixture-concurrency issue was not changed as part of F01. The four skips cover the optional Hoodi supplied-token test, the factory code-size override test, the live production-oracle check requiring `ETH_RPC_URL`, and the live official-bundle interface check. No mainnet or live-chain verification is claimed.

Final commands used for serial verification and snapshot refresh, with `forge` resolved to `/Users/andreikorokhov/.foundry/versions/foundry-rs/foundry/v1.8.1/forge`:

```sh
FOUNDRY_PROFILE=snapshots UPDATE_RECIPE_MANIFESTS=false forge test --offline --isolate \
  --no-match-contract '.*(Mainnet|Benchmark|Invariant).*' --gas-report \
  --gas-snapshot-emit false --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots forge test --offline --isolate \
  --match-contract '.*Invariant.*' --gas-snapshot-emit false \
  --gas-snapshot-check false --threads 1 --fuzz-seed 0
FOUNDRY_PROFILE=snapshots forge test --offline --isolate --match-contract RecipeRecoveryTest \
  --match-test 'test_(RecoveryWithdrawsMorphoThenAaveRepaysThenRequestsInOrder|GasOptimizedFullyFundedRecovery)' \
  --gas-snapshot-emit true --gas-snapshot-check false --threads 1 --fuzz-seed 0
```

The refreshed example retains all 97 instructions, identical queries/opcode requirements, and identical runtime action instructions; only numerical/read instructions 53–57 and the commitment change. The full pinned-toolchain `forge build --offline` passed with compiler warnings in unrelated source/dependency files. Repository-wide `forge fmt --check`, scoped Prettier checks, and `git diff --check` passed. The changes remain uncommitted and have not been published or deployed.

Plan004 execution: lending examples 49→48 steps / −160 encoded bytes; isolated executor gas 785,197→781,661 (sync) and 791,927→788,391 (async). All 2,147 runnable integrated tests and 18 invariant-selection tests pass, with four existing optional configuration skips. Evidence is in Plan004 and ignored out/plan004/.

Plan 005 execution: recovery97→96 steps (conditional98→97), −160 encoded bytes; three gas fixtures save 3,546–3,602 with byte-identical claim/repay controls. All 2,156 integrated tests and 18 tests in invariant suites pass, with four existing optional configuration skips. Exact benchmark selectors were corrected for Foundry function signatures. Evidence is in Plan005 and ignored out/plan005/.

Plan006 execution: the decoder prototype saved 11,526–33,575 gas in executor templates but regressed capability fixtures by 31/21/3 gas. It is REJECTED; all three production files and the temporary packing-harness adaptation are restored byte for byte. All fourteen restored workloads equal baseline. Differential reference tests and measured rejection evidence remain.

Plan007 execution: the combined scalar/call prototype failed small/control gas and exact-ABI gates. The independent scalar-only prototype preserved ABI but regressed cachedTupleReads by 12 gas and other controls by 11–175 gas. It is REJECTED; the production interpreter is restored byte for byte. Frozen response/revert/effect tests and measured rejection evidence remain.

Final Plan007 restored verification: 2,187 integrated tests pass with zero failures and four existing optional skips; 18 tests in invariant suites pass with no skips. All 21 gas labels, both ABIs and deployed sizes equal baseline. All twelve generated outputs remain byte-identical. Format/build/scope gates pass.

Plan008 execution on2026-10-13: retained after structural RED/GREEN,6 old-source
semantic tests and strict frozen gas514,547→510,732 (−3,815). Query hashes and
four/one runtime slots unchanged; all12 saved outputs byte-identical. Claims36/0/0,
scoped108/0/0, full local2,214 passed/0 failed/4 existing skips, invariants18/0/0;
code-size environment case separately1/0/0. Build, format, generated/scope gates
passed; snapshots regenerated (size report unchanged). See
[Plan008 evidence](008-claim-progress-witnesses.md#execution-evidence--2026-10-13)
and `out/plan008/execution-report.md`. Setup auto-initialized pinned submodules and
removed the lock newline; the controller excludes that setup-only lock delta from
delivery and verifies original lock bytes against its independent baseline. Plans
009/010 still require their own fresh baselines and gates.

Plan 009 completed locally on 2026-10-13 after verified O08. Safe capped identity minima save one 192-byte instruction per qualifying output: claim-bounded 12/3,008→11/2,816 and health-claim-ready 57/11,104→55/10,720. Frozen bounded executor gas improves 149,212→145,223 and639,433→631,377; both uncapped controls remain exactly 510,732 and607,602. Checked overflow, invalid literal widths/error order, exact debits and rollback remain protected. Final verification: 2,234 local tests plus 18 invariants pass,0 failures, 4 unchanged optional skips; scoped 212 and snapshot-profile 140 pass. Only the two capped manifests change, with exact queries/runtime/action meaning preserved and ten other outputs byte-identical. Build, formatting, scope and independent spec/quality review pass. Full ledger is `out/plan009/execution-report.md`; controller integrates/commits separately. No push, PR, deployment or published commitment adoption is claimed.
