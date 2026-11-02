# Recipe optimization follow-up

Reviewed on 2026-10-12 against HEAD `901c82ca0339d27748af414e537a6d47a0643ec3`, branch `codex/merkle-staging-forwarder`, and the current dirty working tree. This is a read-only advisory review after local completion of F01 and O01–O03. Those completed changes and unrelated in-progress changes were preserved. Only this report and the plan index were edited.

No additional reachable correctness or security defect was confirmed in the reviewed recipe scope. One new small builder optimization was found. Three previously recorded candidates remain worth considering. Structural reductions below are verified projections; no new gas savings were measured.

## Recommended findings

| ID  | Finding                                                            | Category                             | Impact                                                                                                                        | Effort | Fix risk                                                       | Confidence                                     | Evidence                                                                                                                         |
| --- | ------------------------------------------------------------------ | ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| O04 | Omit lending positivity when its output minimum already implies it | Builder performance; new             | Current synchronous and asynchronous lending examples each go from 49 to 48 instructions, saving 160 ABI-encoded bytes        | S      | Low with the exact raw-unit threshold                          | High on reduction; gas unmeasured              | `script/recipes/LendingRecipe.sol:91`, `:122`, `:127`, `:152`                                                                    |
| O05 | Omit the initial recovery health clamp after checking the trigger  | Builder performance; reconfirmed     | Current health-recovery example goes from 97 to 96 instructions, saving 160 ABI-encoded bytes                                 | S      | Low when restricted to the initial snapshot                    | High on reduction; gas unmeasured              | `script/recipes/RecoveryRecipe.sol:117`, `:119`, `:340`, `:377`                                                                  |
| O06 | Decode executor steps once                                         | Interpreter performance; reconfirmed | Removes duplicate opcode/payload extraction for each shared-interpreter step; net gas gain needs measurement                  | S      | Low semantic risk; IR stack pressure can offset savings        | High on duplicated work; medium on net benefit | `src/contracts/merkle-adapter/automations/RecipeExecutor.sol:74`, `:118`; `src/contracts/merkle-adapter/Recipes.sol:46`          |
| O07 | Copy only required successful return data                          | Interpreter performance; reconfirmed | Ordinary reads consume one word and direct calls discard successful response bytes; potential gain grows with response length | M      | Medium: low-level error and return semantics must remain exact | High on copying pattern; medium on net benefit | `src/contracts/merkle-adapter/Recipes.sol:60`, `:66`, `:78`; `lib/openzeppelin-contracts/contracts/utils/Address.sol:83`, `:100` |

Recommendation: select O04 and O05, then benchmark O06. Treat O07 as a separate benchmark candidate after O06 establishes the runtime baseline. O04/O05 are independent template changes; O06/O07 touch the shared interpreter and should be measured separately. The user subsequently selected O04–O07 for plans 004–007, indexed in README.md. This selection authorizes planning only; no candidate implementation or new gas measurement has been performed.

All selected changes must preserve action order, runtime payload slots, checked arithmetic, authorization and rollback. Builder reductions change instruction indices, recipe bytes and commitments. Saved manifests and any downstream named operands must be regenerated from the rebuilt recipe before adoption.

## O04: lending output positivity

The builder checks `borrowAmount >= 1`, then requires the observed borrowed cash delta to equal that amount. Its minimum output is:

```text
minimumRwa = borrowedUsdc * minRwaPerUsdcWad / 1e6
```

When `minRwaPerUsdcWad >= 1e6`, every successful checked multiplication/division produces `minimumRwa >= borrowedUsdc >= 1`. The existing minimum-output check at line 153 therefore implies the positive-output check at line 152. Both saved lending examples configure `minRwaPerUsdcWad = 0.99e18` and qualify. The threshold is **1e6**, because this template converts six-decimal USDC amounts into eighteen-decimal RWA units; it is not the 1e18 threshold used by other templates.

For rates below 1e6, a positive input can produce a zero floor, so the positivity check remains necessary. Keep the minimum calculation even when factors look cancellable: checked multiplication overflow is part of runtime behavior. Preserve all cash/receipt/debt observations, exact spend checks, debt rounding protection, approval handling and final cash equality. Both direct RWA balance output and normalized asynchronous purchase-receipt output use the same implication.

Useful validation boundaries are zero rate, 999999, 1e6 and 1e6 + 1; a one-unit borrowing amount; zero output and rollback; checked full-width multiplication overflow; both purchase modes; and unchanged runtime action layout. These describe evidence requirements for a selected plan, not an implementation performed by this review.

## O05: initial recovery health clamp

Recovery first checks `initial.health <= triggerHealthFactor`. Configuration rejects `targetHealthFactor <= triggerHealthFactor`. Thus the initial snapshot already satisfies `initial.health < targetHealthFactor`, making its `Min(initial.health, targetHealthFactor)` redundant.

Restrict this specialization to the initial need calculation. Later health snapshots can change after actions and still require their clamp. Health claims and settled-cash repayment also lack this initial trigger bound. Preserve the trigger check and all checked multiplication, division and subtraction. A narrow template change has a much smaller scope than adding generic range inference to the builder.

The saved health-recovery manifest has 97 instructions. Its trigger comparison, Min and MulDiv occur at indices 3, 4 and 5; removing only index 4 projects 96 instructions. The conditional two-group fixture also loses one instruction, from 98 to 97.

## O06: decode once, then measure

`RecipeExecutor.execute` extracts the opcode and payload at line 74, and `_run` extracts the same pair again at `Recipes.sol:46` for every non-action step. Passing the already extracted values into the shared interpreter could remove repeated work. `RecipeCapability` currently enters the interpreter with only one extraction and must retain that behavior.

This is a source-level opportunity, not a measured runtime improvement. Solidity's via-IR optimizer and changed stack pressure can reduce or reverse the gain. Retain a refactor only after representative lending, recovery, claim, LL and capability measurements improve without material regressions. Differential checks must preserve empty-step panics, malformed payload/reference failures, evaluation order, numerical results, runtime slots and capability call context.

## O07: selective successful return-data copies

Ordinary Read and active ReadIf copy the complete static-call response before selecting a single word. Direct Call/CallIf copy a successful response which the interpreter discards. OpenZeppelin's current Address helpers perform those full copies; the shared interpreter intentionally uses them for error behavior.

A scalar-read path could validate total response length and copy only the selected 32 bytes. A no-result call path could avoid copying successful response bytes. Neither applies to ReadCached: that operation must retain the full latest response for ReadWord.

Preserve exact upstream error selectors and bubbled revert bytes, empty-code behavior, offset-plus-32 overflow panics, short-response InvalidQuery, unaligned offsets, and cached-response identity. Benchmark ordinary 32-byte ERC20 responses as well as realistic multiword getters; synthetic large responses alone would overstate typical savings. Implementing a replacement before measuring these workloads is not justified.

## Lower-priority and investigation candidates

- **Zero debt tolerance:** `RecoveryRecipe.sol:408–409` uses two opposite comparisons. When the configured tolerance is zero, one equality can replace both, saving one instruction / 160 ABI bytes. Current examples use tolerance one, so they would not benefit. Do not remove their rounding protection. Effort S, risk low, high confidence on the restricted reduction.
- **Calldata metadata views:** queries/calls and Manage decode immutable binding metadata into memory. Manual calldata views may reduce copying, but must preserve bounds, failure order and accepted relocated/shared ABI tails, explicitly tested in `RecipeExecutorReview.t.sol:435–507`. Effort M–L, risk medium to high, performance payoff unmeasured. Defer behind O06/O07.
- **Discarded Manage responses:** `RecipeExecutor.sol:87` ignores the typed `bytes[]` result, while approval handling at lines 112–115 consumes it. Investigate whether ordinary Manage response handling can avoid materializing unused buffers while preserving existing malformed-return rejection and atomic rollback. Effort M–L, risk high, optimization confidence low until compilation and measurements establish the cost. Simply ignoring all response validation is not a behavior-preserving change; approval responses must still be checked.

The earlier optional deployment preflight and issuer-profile directions remain unselected. This follow-up does not establish additional product direction or live issuer compatibility.

## Considered and rejected

- Completed F01 and O01–O03 are not new findings. The earlier report's candidate for conditional standalone-claim reads is already part of the current baseline.
- A fresh scan found no reversed-operand duplicate Add/Min/Max/Equal expressions in the eleven current top-level saved manifests. Commutative deduplication has no demonstrated example benefit here.
- Generic read caching and carrying cash across action, approval or cleanup barriers can change observations. Preserve fresh health/debt reads and the existing explicit stable-ERC20 assumption.
- Cancelling multiplication/division factors can hide checked overflow. It is not an equivalent optimization.
- Moving a Manage gate ahead of committed dynamic decoding changes malformed-instruction rejection.
- Broad health-bound propagation is unsafe across fresh reads. Only the initial recovery bound supports O05.
- Guarded 3F shared-input compaction changes the leaf/API and permission commitment. Existing tests deliberately vary the input pairs; treat it as an optional format redesign.
- No material new offchain builder bottleneck was demonstrated. Quadratic scans and skipping zero-result stores do not justify extra machinery without measurements.
- The known parallel testnet fixture environment race and unrelated deployment/ThreeF changes are outside this follow-up's recipe scope.

## Verification and limits

Reviewed all nine top-level Solidity recipe files, their direct interpreter/executor/capability and account consumers, relevant tests and docs, and eleven saved top-level manifests. Two independent read-only agents covered correctness/security and runtime opportunities; the parent verified the recommended source references. This was a scoped follow-up, not another whole-repository security audit.

Read-only checks established the current 49-instruction lending and 97-instruction recovery baselines, their instruction positions, and the absence of reversed-operand matches. A Python arithmetic model verified 6,035 successful-product lending boundary cases; 1,007 overflowing products were excluded from that implication and remain mandatory checked failures. Another 10,000 valid trigger/target cases confirmed the initial health-clamp identity. These are mathematical checks, not Solidity regression runs.

The existing Plan003 scope check passed before the follow-up prose was written, confirming the same nine implementation paths against its captured baseline. No source, test, manifest, snapshot or build output was changed by this review. No formatter, patched Foundry suite or new benchmark was run. The prior completed implementation's passing tests are documented in the index; they do not demonstrate the proposed reductions.

Not verified: new gas savings, selected-candidate implementations, sibling Go/frontend compatibility, deployed permissions/contracts, wallets, live-chain execution, mainnet forks, hosted CI, deployment or publication. Future execution must use the pinned Foundry 1.8.1 / Solidity 0.8.37 via-IR, optimizer 200 and Osaka configuration, preserve the dirty baseline, and run the repository's relevant local tests and artifact checks. Use serial broader validation because of the existing testnet fixture race.
