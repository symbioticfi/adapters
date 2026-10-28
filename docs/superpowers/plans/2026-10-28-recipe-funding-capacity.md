# Recipe funding capacity implementation plan

**Goal:** Discover Liquid Lane funding capacity on-chain from the exact committed funding prefix.

**Architecture:** The connector binds each RWA to its account's recipe executor. The executor stores an authenticated funding-prefix capsule, runs its actual prepared reads and managed withdrawals, and always rolls that simulation back before returning the account's resulting funding-token balance.

**Constraints:** Keep the existing recipe interpreter and hash; use the installed SSTORE2 library; use no-argument errors. Capacity is the ordered maximum-input funding probe, not proof of full-fill execution or a reservation. Missing bounds, stale recipes/proofs and source failures fail closed.

1. Add a failing shared-liquidity and rollback test, then implement `setCapacity(asset, queries, steps, prefixEnd, inputs, runtime)` and `capacity()` in `RecipeExecutor` by extracting its existing execution loop.
2. Keep all simulation writes inside an always-reverting helper. A second self-only execution helper normalizes source failures before the outer helper returns a raw result through revert data. Bind that helper to the stored capsule and a transient preview context.
3. Add connector `recipeExecutors`, account-only `setRecipeExecutor`, and non-view `getMaxAssets`, validating account and asset and clipping by `remainingAssets`.
4. Expose `LLExecuting.Layout.fundingEnd` and canonical capacity inputs `[1, uint256.max]`; update interface documentation and template setup output.
5. Test preparation, shared liquidity, prefix boundary, real-transaction rollback, spoofed revert data, self-call authorization, stale recipes/proofs, capsule limits, binding and budget clipping.
6. Run the local Foundry suite and pre-commit gates, review the diff, then commit without pushing.
