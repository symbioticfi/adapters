# Restored recipe interpreter benchmarks

Historical measurements for the first rollback (`48d750e`). That version retained
executor-only conditional approval cleanup, which has since been removed.

`Recipes.sol` is byte-identical to `bd5e235899de5e175a0001a913d47596f6f4f801`.
The baseline is branch head `b46c03824b4229be5dddfa02d6a71d77440bfbff` before the rollback.
Both versions use Foundry 1.8.5, Solidity 0.8.37, via IR, optimizer 200, Osaka and no bytecode metadata hash.

24 cases pass on each version, producing 25 execution snapshots. The same fixture balances,
protocol actions, proof depths and signer setup are used in both versions. Measurements use
`vm.snapshotGasLastCall` with isolation and exclude deployment and recipe construction.
These are local fixture measurements, not live protocol estimates.

Runtime bytecode shrinks from 7,329 to 6,726 bytes for `RecipeExecutor` and
from 2,694 to 2,097 bytes for `RecipeCapability`.

| Fixture                                             |    Before |     After |             Change |
| --------------------------------------------------- | --------: | --------: | -----------------: |
| `CallIfGasFunding/neededOptimized`                  |   246,773 |   263,651 |   +16,878 (+6.84%) |
| `CallIfGasFunding/neededStandard`                   |   244,914 |   234,307 |   -10,607 (-4.33%) |
| `CallIfGasFunding/skippedOptimized`                 |    86,451 |   178,088 | +91,637 (+106.00%) |
| `CallIfGasFunding/skippedStandard`                  |    93,016 |   148,751 |  +55,735 (+59.92%) |
| `CallIfGasLL/neededOptimized`                       |   839,919 |   878,727 |   +38,808 (+4.62%) |
| `CallIfGasLL/neededStandard`                        |   883,204 |   866,800 |   -16,404 (-1.86%) |
| `CallIfGasLL/skippedOptimized`                      |   651,124 |   708,960 |   +57,836 (+8.88%) |
| `CallIfGasLL/skippedStandard`                       |   711,172 |   697,044 |   -14,128 (-1.99%) |
| `CallIfGasThreeF/twoSources`                        | 1,032,209 | 1,044,396 |   +12,187 (+1.18%) |
| `CallIfGasThreeF/twoSourcesCached`                  | 1,010,565 | 1,044,396 |   +33,831 (+3.35%) |
| `LLExecuting/O03LLPositiveMinimum`                  |   868,339 |   861,187 |    -7,152 (-0.82%) |
| `LLExecuting/twoActiveSourcesConditional`           |   825,040 |   873,064 |   +48,024 (+5.82%) |
| `LLExecuting/twoActiveSourcesUnconditional`         |   868,339 |   861,187 |    -7,152 (-0.82%) |
| `RecipeCapability/executeChecksAndBindings`         |   155,383 |   154,244 |    -1,139 (-0.73%) |
| `RecipeCapability/executeEmpty`                     |    57,766 |    57,766 |        +0 (+0.00%) |
| `RecipeCapability/executeReadAndCheck`              |    84,277 |    83,829 |      -448 (-0.53%) |
| `RecipeClaims/claimRedemptionWithdrawalMintRewards` |   513,339 |   562,914 |   +49,575 (+9.66%) |
| `RecipeExecutor/executeCall`                        |    81,417 |    81,111 |      -306 (-0.38%) |
| `RecipeLending/O04Async`                            |   791,765 |   782,505 |    -9,260 (-1.17%) |
| `RecipeLending/O04Sync`                             |   785,035 |   775,775 |    -9,260 (-1.18%) |
| `RecipeRecovery/O01TwoActiveClaims`                 |   613,207 |   651,476 |   +38,269 (+6.24%) |
| `RecipeRecovery/O01TwoActiveSources`                | 1,131,191 | 1,241,578 |  +110,387 (+9.76%) |
| `RecipeRecovery/O03HealthClaim`                     |   607,576 |   597,280 |   -10,296 (-1.70%) |
| `RecipeRecovery/recovery`                           | 1,112,312 | 1,094,612 |   -17,700 (-1.59%) |
| `RecipeRecovery/repaySettledCash`                   |   337,740 |   331,969 |    -5,771 (-1.71%) |

`Optimized`, `Conditional` and `Cached` are stable identifiers for the former optional modes.
Cached 3F reads now compile to ordinary reads, so the two 3F modes have the same execution cost.
Legacy conditional-read flags compile to arithmetic selection and can cost more than leaving them disabled.

Preparation is now unconditional. In the funding toy fixture, an otherwise unused preparation writes
three new storage values, increasing the default skipped-source path by 55,735 gas. In the LL
fixture it rewrites unchanged liquidity, so that fixture has a different cost. These figures are
not interchangeable estimates for arbitrary preparation calls.

Claims and conditional modes lose lazy queries. An unavailable query now reverts even if its
associated action is skipped. An unused preparation can also revert or change state.

The rebuilt 3F sequence accepts `[request, principal, yield]`. Its committed executor bindings
write the same request into all nested targets and arguments. The account capability validates
live authorization, consumes policy, approves, mints and checks exact balances and budget debit.
A new auction using the same funding pair retains the same recipe and leaf.

Run the current measurements from the repository root:

```sh
FOUNDRY_TEST=docs/benchmarks forge test --isolate --threads 1 \
  --match-contract '^CallIfGas.*' --match-test '^test_CallIfGas' \
  --gas-snapshot-emit false --json-file out/recipe-runtime-gas.json
```

Use Foundry 1.8.5 for `forge`. The harness is
[RecipeRuntimeGas.sol](benchmarks/RecipeRuntimeGas.sol); the complete numbers are in
[recipe-runtime-gas.json](benchmarks/recipe-runtime-gas.json). To reproduce the baseline, use
a separate checkout at the baseline commit with the same dependencies, copy this harness into
`docs/benchmarks/`, and run the identical command. The recorded before/after runs used isolated copies and matching snapshot keys;
every case passed.

The broad local suite passed 2,209 tests before the final manifest-serialization fix;
both previously failing Sepolia manifest tests pass with that fix. One unrelated
registry fuzz test, `testFuzz_ProposalReplacementAndCancellationClearPreviousData`,
also fails at the unchanged baseline with the same counterexample. Snapshot
regeneration excludes that test. Mainnet fork execution was not run.
