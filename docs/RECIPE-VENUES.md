# Native venue recipes

[`SynchronousVaultRecipe`](../script/recipes/SynchronousVaultRecipe.sol) compiles the common synchronous ERC-4626 deposit and withdrawal flow into the existing recipe opcodes. It is a script library, so the account, capability and executor contracts do not need another deployment or protocol dispatch branch.

Use it only after the protocol's native integration has verified the selected vault and its asset. The metadata name or ERC-4626 interface alone does not establish admission. Queued withdrawals, position NFTs, credit accounts, delegated ownership, vaults with reverting previews and intermediary receipt tokens need their native lifecycle recipe. In particular, Upshift's `requestRedeem`/dated claims and BoringVault teller/queue routes cannot use the synchronous withdrawal builder.

The leaves pin the token, vault, account and recipient. The approval leaf allows only the approval amount word to change; the deposit and withdrawal leaves allow only the assets word at calldata offset 4 to change. Runtime payloads provide those exact approved leaves and proofs. A runtime payload cannot change the vault or send output to another recipient.

- Deposit amount is `min(account balance, policy cap, vault.maxDeposit(account))`. A policy cap expresses risk limits; the actual amount comes from execution-time state. The recipe checks the exact asset spend, native `previewDeposit` output with the configured slippage tolerance, positive shares for a positive spend, and clears the remaining token approval.
- Withdrawal amount is `min(max(required idle assets - current account balance, 0), vault.maxWithdraw(account))`. The required idle amount comes from a committed on-chain query. The recipe checks the exact assets received and a maximum share burn derived from the execution-time `previewWithdraw`. It never repays, borrows or unwinds another position.

All reads execute even for a zero amount. Reviewed venues must therefore support the native zero-value previews. The manage step skips the external financial action when the computed amount is zero.

`SynchronousVaultRecipeTest` executes these programs through the production MerkleAccount, RecipeCapability and RecipeExecutor against local venue effects. It covers live balance/capacity changes, zero shortfall, approval cleanup, native asset binding, recipient substitution, output slippage, excess share burns and short asset payments. These tests establish recipe semantics and authorization; they do not prove mainnet execution of every venue.
