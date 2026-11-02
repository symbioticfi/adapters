# Additional recipe optimization review

Reviewed on 2026-10-12 against HEAD `901c82ca0339d27748af414e537a6d47a0643ec3` and the current dirty working tree. This includes the new standalone ClaimRecipe, settled-cash repayment recipe, and LL redemption changes. This is an advisory review; no source or snapshot changes were made. F01 remains a completed correctness fix.

## Recommended opportunities

| ID  | Change                                                                   | Concrete saving                                                                             | Effort                          | Risk                                                       | Confidence                                           |
| --- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- | ------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------- |
| O01 | Carry the cash snapshot between conditional recovery source/claim groups | With two active groups, the cash-read section goes from six external balance reads to three | M, including differential tests | Medium: zero gates must preserve the previous cash operand | High on redundant reads; gas saving unmeasured       |
| O02 | Track standalone claim progress with maxima                              | One fewer numerical instruction per output; five in the four-group/five-output test fixture | S                               | Low if both group and global accumulation change           | High on instruction reduction; gas saving unmeasured |
| O03 | Remove positive-output checks implied by the configured minimum          | Two instructions per qualifying claim group; one in LL redemption                           | S                               | Low with the exact raw-unit rate condition                 | High on instruction reduction; gas saving unmeasured |

O02 and O03 are independent but touch ClaimRecipe together. Apply O02 before O03 when measuring cumulative reductions. O01 is independent. All three change recipe bytes/indices and require regenerated manifests and publication before adoption. Named operands and runtime layouts must be derived from the rebuilt recipe.

Planning refresh: concurrent work subsequently added bounded/pending-free claims, conditional standalone output reads, LL amount bindings/retained-inventory redemption, and more examples. The plans preserve these changes and measure relative reductions against a fresh passing catalogue baseline. Historical absolute instruction counts and source line references below describe the earlier reviewed snapshot; they must not override the plans' current gates. The conditional standalone-read candidate below is now implemented in that concurrent baseline.

## O01: carry recovery cash between groups

Evidence:

- `script/recipes/RecoveryRecipe.sol:115`, `:128`, `:179`, and `:187` take an initial cash snapshot and another before repayment.
- `_source` at `:240-245` emits two conditional balance reads for each source.
- `_claim` at `:298-305` emits two conditional cash reads for each claim.
- `script/recipes/ExecutingRecipe.sol:176-178` recognizes only ordinary `Read` for automatic balance reuse; a conditional post-action balance is not reused by a later `balance` call.

Under `skipUnusedReads=true`, carry `initial.cash` into the first group and each group's fresh post-action cash into the next. The post-action `ReadIf` must use the previous cash operand as its zero-gate fallback. The before-repayment snapshot can reuse the final carried cash while still reading fresh health and debt. Each active action retains its exact cash-delta check.

For N >= 1 groups with read-derived gates, this removes N conditional pre-action read instructions and one ordinary before-repayment cash read. The external-call saving is activeGroupCount + 1. Two active groups currently perform initial + two reads per group + final = six cash calls; the proposed path performs initial + one post-action read per group = three. For two groups, the source-derived encoded-size reduction is 512 bytes: two removed 97-byte ReadIf steps contribute 192 ABI bytes each, plus 128 for the removed 33-byte Read step. The query definition remains in use.

Boundaries: retain reads across repayment approval and approval cleanup; retain fresh health/debt snapshots, pending/capacity reads, and final cash checks. This uses the same stable standard-ERC20 balance assumption as the existing balance helper. Do not cache arbitrary generic getter results. Zero configured groups already benefit from ordinary balance reuse; the N+1 formula does not apply there.

## O02: simplify standalone claim progress

`script/recipes/ClaimRecipe.sol:96-101` computes group progress as the sum of `min(delta, 1)`, then adds group progress into total progress. These operands are only used to establish whether a group/whole run received any output; neither is exposed in a named layout or action binding.

Replace both levels of addition with `max`. For nonnegative deltas, `sum(min(delta,1)) >= 1` is equivalent to `max(delta) >= 1`; the group threshold `min(amount,1)` is also preserved. The first max with zero folds away, while each later output replaces Min+Add with one Max. This removes exactly one instruction per output: five instructions / 800 encoded ABI bytes in the existing four-group/five-output fixture at `test/adapters/merkle-adapter/RecipeClaims.t.sol:303-315`; eight in its eight-output fixture.

Both group and global accumulation must change. Adding full-width maxima across groups could introduce overflow that the old bounded counts avoid. Retain all checked output subtractions, minimum-output multiplication/division, per-group success guards, and the final nonempty-run check. Recipe instruction values/indices change, as with other builder optimizations.

## O03: omit logically implied positivity guards

When a group's required raw-unit rate satisfies numerator >= denominator > 0, the checked minimum-output calculation yields minimum >= amount. Its minimum-output check already proves a positive output for every positive amount. Fractional rates can round down to zero and still need the separate positivity guard.

- Standalone claims: `script/recipes/ClaimRecipe.sol:87-98`. If any required output has that rate, omit the group's `Min(amount,1)` and group positivity check. The current test fixture qualifies for groups 1, 2, and 3, removing six instructions / 960 ABI bytes. Combined with O02, that fixture removes eleven instructions / 1,760 bytes. The one-output `claim.json` example goes from 11 to 8 instructions / 480 fewer bytes with O02 and O03 combined.
- Health claims: `script/recipes/RecoveryRecipe.sol:293-307`. When `minAssetPerClaimWad >= 1e18`, omit its boolean Min and positive-output check. Both configured example claims use 1e18, projecting `health-claim` from 61 to 57 instructions / 640 fewer bytes.
- LL redemption: `script/recipes/LLExecuting.sol:101-122`. `amountIn >= 1` is already checked at `:65`; with minimum numerator >= denominator > 0, omit `1 <= received`. The current example uses 1/1, projecting 45 to 44 instructions / 160 fewer bytes.

Retain the minimum-output arithmetic even when numerator equals denominator: cancelling equal factors would hide checked multiplication overflow. Keep every balance/receipt read, checked subtraction, minimum-output check, and action ordering. The omitted comparisons have the same CheckFailed selector as the retained stronger comparison.

## Lower-priority candidates

- **Initial recovery health clamp:** `RecoveryRecipe.sol:116` proves saved initial health <= trigger, and `:315-318` requires target > trigger. The initial `Min(health,target)` in `_need` at `:340-343` is redundant. Current saved instructions 3-4 confirm the match. Removing it projects 97 -> 96 instructions / 160 bytes. A narrow template specialization is small; a general range-inference optimizer is more complex than this example justifies. Do not propagate the bound to fresh health reads.
- **Zero debt tolerance:** `RecoveryRecipe.sol:373-374` can emit one Equal instead of opposite LessOrEqual checks when debtTolerance == 0. One instruction / 160 bytes; checked examples use tolerance 1.
- **Decode each executor step once:** `RecipeExecutor.sol:74` decodes the same nonaction step again in `Recipes.sol:45`. Independent compilation with the pinned Solidity/IR configuration reproduced the current bytecode and retained both decodes. Small internal refactor; benchmark before retaining because stack spilling may offset savings.
- **Copy only needed return data:** ordinary reads at `Recipes.sol:59-65` use one word after copying the full response; direct calls at `:70` discard the copied response. `Address.sol:83-85`, `:100-102`, and `LowLevelCall.sol:104-108` establish the copy. Compiled IR retains it. A scalar/no-result path is a medium-effort benchmark candidate, especially for long getter responses. Preserve exact upstream errors/revert data, offset overflow checks, short responses, unaligned offsets, and full ReadCached snapshots.
- **Calldata metadata views:** queries/calls decode immutable bindings into memory (`Recipes.sol:56-58`, `:67-69`); Manage also copies leaves/nested bindings (`RecipeExecutor.sol:77-78`). A custom decoder could reduce copying, but must preserve bounds checks and accepted relocated/shared ABI tails (`RecipeExecutorReview.t.sol:434-507`). Medium-to-large effort and medium risk; benchmark value is unproven.
- **Guarded 3F input compaction:** the generated leaf carries principal/yield twice (`ThreeFGuardedMint.sol:106-135`, `ThreeFExecuting.sol:90-94`). Two shared inputs could remove 64 bytes each from nested inputs, the action mask, and outer bindings. This changes the generated leaf/API and requires role publication; direct tests deliberately vary the two input pairs. Treat it as an optional format change, not an automatic behavior-preserving pass.
- **Conditional standalone claim reads:** `ClaimRecipe.sol:72-74`, `:82-84` still read outputs for zero-claimable groups. An explicit ReadIf option could skip two calls per inactive output, but would deliberately stop unused query failures from blocking other groups. This is a new application of an existing option, with a strategy tradeoff, not automatic read reuse.

## Considered and rejected

- Reversed-operand deduplication and self-subtraction/min-zero simplification are possible generic additions, but none matched the seven current example manifests. They are lower value than reachable template reductions.
- Generic read caching remains unsafe without an explicit snapshot contract; getters can depend on execution context. Existing fresh-read semantics are intentional.
- Carrying cash across approval or cleanup barriers would remove protection against side effects; those reads remain necessary.
- Moving a Manage zero-gate check before dynamic decoding changes rejection of malformed committed instructions. Do not call it behavior-preserving.
- ClearApproval does not duplicate its allowance query: amount zero short-circuits the later expression.
- Quadratic offchain scans were already considered in the earlier review; no new builder-time bottleneck was demonstrated.

## Verification performed and limits

Read all current builder templates, their direct executor/capability consumers, relevant local tests, and seven saved manifests. Three independent read-only reviews covered builder algebra, template reads/checks, and interpreter execution. Parent review confirmed the cited source locations and byte contributions. A Python boundary model checked 19,600 claim-positivity equivalence cases and 259 positive-rate implication cases, including zero and full-width values. Removed binary instruction sizes were decoded from the saved claim bytes (65 raw bytes, 160 bytes per ABI array element including its offset/length/padding).

These are instruction/read-count projections and mathematical checks. No candidate implementation, patched Foundry test, fresh gas benchmark, live RPC check, sibling Go/frontend compatibility check, hosted CI, or deployment was performed.

For implementation, use pinned Foundry 1.8.1 and Solidity 0.8.37 with IR, optimizer 200 and Osaka. Add differential effects/revert tests at zero, one, fractional-rate rounding, full-width multiplication overflow, inactive groups, two active sources/claims, and incorrect protocol deltas. Preserve action order and runtime slot counts. Run scoped RecipeClaims/RecipeRecovery/LLExecuting/RecipeOptimization suites with fixture and snapshot writes disabled first; then regenerate only selected manifests/snapshots and review their hashes/layouts. Broader local validation should run serially because the existing testnet environment fixtures can race.

The user selected implementation plans for O01-O03. Plans 001 (O02), 002 (O03), and 003 (O01) are indexed in README.md. This is authorization to prepare the plans; source implementation and recipe publication have not been performed.
