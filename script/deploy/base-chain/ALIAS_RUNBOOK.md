# Alias-controlled 3F maker on Base

An Ethereum `MerkleAccount` controls a stock OpenZeppelin `AccessManager` on Base. The MerkleAccount's OP Stack alias
is the sole `ADMIN_ROLE` holder at deployment, with zero execution delay. The AccessManager is the 3F maker. It holds
the USDC, PT and YT, and owns the `ThreeFPolicy` bound to it on Base.

```text
Ethereum: mint operator -> RecipeExecutor -> MerkleAccount.manage -> Base OptimismPortal
Base:     MerkleAccount alias -> AccessManager.multicall
            -> execute(policy.beginPushMint) -> execute(USDC.approve)
            -> execute(request.mint) -> execute(USDC.approve(0))
            -> execute(policy.finishPushMint)
```

The Ethereum recipe caps the principal and binds the request and offer bounds to every use of those values in the
batch. The Base policy authenticates the request and charges the live principal and yield authorized for the manager.
A policy rejection stops the mint. A later failure, including a mint that fails to debit the exact principal, rolls
back the budget charge, mint and approval in the same Base transaction.

See the [Safe runbook](RUNBOOK.md) for the Safe-based deployment.

## Deploy and configure

1. Set `BASE_ALIAS_MANIFEST=deployments/base-alias.json`, `BASE_ETHEREUM_ACCOUNT` to the Ethereum MerkleAccount, and
   `BASE_FACTORIES_OWNER` to the policy factory owner. Run `DeployBaseAliasPolicy.s.sol` against `BASE_RPC_URL`.
   Add `--broadcast` to deploy and write the manifest.
2. Run `BuildBaseAliasLeaves.s.sol` with the manifest and `BASE_ALIAS_LEAVES` set to the output path. Publish the
   resulting leaves in the Ethereum MerkleAccount's root and accept it. Save proofs keyed by leaf hash in
   `deployments/base-alias-proofs.json`.
3. Run `BuildBaseAliasMintRecipe.s.sol` with the manifest, `BASE_ALIAS_MAX_PRINCIPAL` in USDC base units,
   `BASE_ALIAS_RECIPE_OWNER` set to the curator, `BASE_ALIAS_RECIPE_CALLER` set to the mint operator, and
   `BASE_ALIAS_RECIPE` set to the recipe output path. On Ethereum, deploy the RecipeExecutor with the generated
   `factoryCreateCalldata`. Have the curator send `setRecipeCalldata` and `setCallerCalldata` to that executor.
   Grant the `mintThreeF` leaf exclusively to the deployed RecipeExecutor so every mint uses the recipe's bindings.
   Grant the other leaves as listed below.
4. Run `SetThreeFMaxAssetsFromAlias` and `SetThreeFMinYieldFromAlias` on Ethereum for each supported Base underlying.
   On Base, check `remainingAssets(BASE_USDC, underlying)` and `minYieldPerRequest(underlying)`.

If you are replacing an earlier alias setup, settle positions and return any USDC from the previous maker before
retiring its leaves. Install the new proofs and revoke the old mint and approval grants.

### Merkle leaves

| Leaf                      | Executes on | Action                                                           | Runtime fields                            | Role                    |
| ------------------------- | ----------- | ---------------------------------------------------------------- | ----------------------------------------- | ----------------------- |
| `approveBridge`           | Ethereum    | Approve the CCTP TokenMessenger for Ethereum USDC.               | Amount                                    | Funding operator        |
| `bridgeToBaseManager`     | Ethereum    | Burn Ethereum USDC for CCTP delivery to the Base manager.        | Amount                                    | Funding operator        |
| `setMaxAssetsPerDuration` | Base        | Set the policy's Base USDC budget and window.                    | Underlying, budget, duration              | Curator                 |
| `setMinYieldPerRequest`   | Base        | Set the policy's minimum yield ratio, scaled by `1e8`.           | Underlying, minimum                       | Curator                 |
| `mintThreeF`              | Base        | Charge the policy and mint the manager's live authorization.     | Request, maximum principal, minimum yield | Ethereum RecipeExecutor |
| `redeemThreeF`            | Base        | Redeem the manager's entire position in a verified request.      | Request                                   | Funding operator        |
| `bridgeToEthereum`        | Base        | Approve, burn through CCTP to the MerkleAccount, clear approval. | Approval amount, burn amount              | Funding operator        |

The portal leaves pin the manager, zero ETH value, 1,000,000 L2 gas, and the fixed parts of each call. Keep the alias
as the only manager admin. Operational permissions are the Ethereum Merkle leaves above.

### 3F maker enrollment

Use the Base 3F API at `https://bf.3f.xyz/v2/chains/8453`. Have 3F whitelist the broker's signing address and enroll
the **Base AccessManager address** as that broker's maker through manual onboarding. The broker signs requests and
obtains a Base API key through `POST /facilitator/generate-key`. Sign the `GenerateFacilitatorApiKey { facilitator, deadline }`
EIP-712 message with domain `grunt-api`, version `1` and chain ID 8453.

Confirm `isDefault` and `submissionsEnabled` under `GET /facilitator/makers`. If needed, use
`POST /facilitator/offer-address` to set the default maker. Verify that `GET /facilitator/offer-address` returns the
Base AccessManager before funding it.

## Operating a 3F request

1. Size the offer against available USDC, the remaining Base policy budget and the Ethereum recipe's per-mint cap.
   Account for principal already committed to open offers.
2. Send the offer with `POST /offer` and the Base API key. Monitor the offer until it enters `AWAITING_MINT` and
   note its `mintDeadline`.
3. Read `mintAuthorization(manager)` on the Base request. Compare it with the aggregate accepted offers for the
   request. Use the expected principal and yield for the mint bounds.
4. To fund the manager, run `BridgeUsdcToBaseAlias` on Ethereum and relay the Circle attestation with
   `ReceiveCctpMessage` on Base.
5. Simulate the AccessManager batch from the alias against current Base state. Run `MintThreeFFromAlias` on Ethereum
   with the RecipeExecutor, request and offer bounds. Use viem `getL2TransactionHashes` on the Ethereum portal
   receipt to get the Base transaction hash.
6. Check the Base receipt status and the request's PT `Deposit` event. Its sender and owner should both be the
   manager. Confirm the 3F offer reaches `SUCCEEDED`.
7. After repayment, verify the request against Base's 3F RequestFactory and check its `canWithdraw()`. Run
   `RedeemThreeFFromAlias` and check that `balancesOf(manager)` returns zero PT and YT.
8. To return unused USDC, run `BridgeUsdcFromBaseAlias` and relay the Circle attestation on Ethereum with
   `ReceiveCctpMessage`.

### Failed deposits

A successful Ethereum dispatch queues one Base transaction. Check the Base receipt for the mint result. A reverted
Base mint leaves the budget, balance and allowance unchanged. Before retrying, check the request's live authorization,
the mint deadline and the policy budget.

## Scripts and tests

| File                                                       | Purpose                                                     |
| ---------------------------------------------------------- | ----------------------------------------------------------- |
| `script/deploy/base-chain/DeployBaseAliasPolicy.s.sol`     | Deploys the AccessManager and policy on Base.               |
| `script/actions/base-alias/BuildBaseAliasLeaves.s.sol`     | Writes the seven Merkle templates and leaf hashes.          |
| `script/actions/base-alias/BuildBaseAliasMintRecipe.s.sol` | Writes the Ethereum recipe and setup calldata.              |
| `script/actions/base-alias/MintThreeFFromAlias.s.sol`      | Queues the atomic Base mint from Ethereum.                  |
| `script/actions/base-chain/ReceiveCctpMessage.s.sol`       | Relays a Circle attestation on its destination chain.       |
| `test/adapters/merkle-adapter/BaseAliasMint.t.sol`         | Tests the dispatch, authorization and mint rollback.        |
| `test/deploy/BaseAliasPayloads.t.sol`                      | Tests batches, Merkle masks and script proof handling.      |
| `test/deploy/DeployBaseAlias.t.sol`                        | Tests the Ethereum portal and CCTP and the Base deployment. |

Use `ETH_RPC_URL` and `BASE_RPC_URL` for the fork tests.
