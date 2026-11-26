# Base Safe controlled from Ethereum

These scripts move USDC from the Ethereum MerkleAccount to a Safe on Base and run 3F actions in that Safe. All
access control stays on Ethereum: every Base action is a leaf in the MerkleAccount's root.

```text
Ethereum executor -> MerkleAccount.manage -> Base OptimismPortal.depositTransaction
  -> MerkleAccount alias on Base (the only Safe owner and a Safe module)
  -> Safe.execTransactionFromModule(target, CALL)                      policy setters
  -> Safe.execTransactionFromModule(Safe, CALL)
       -> Safe.execTransactionFromModule(RecipeCapability, DELEGATECALL) 3F mint and redeem, bridge back
  -> Safe.approveHash(hash)                                            one-time ERC-1271 messages
```

The portal gives a contract sender an alias on Base: its address plus
`0x1111000000000000000000000000000000001111`. The alias is the Safe's only owner, with threshold 1, and a module. No
key on Base controls the Safe. It also enables itself,
because `RecipeCapability.execute` only runs when the Safe calls itself. USDC moves with CCTP v2 Standard Transfer,
which has no fee.

## Contracts

| Base contract                  | Notes                                                                        |
| ------------------------------ | ---------------------------------------------------------------------------- |
| Safe v1.4.1 (`SafeL2`)         | Owner: the MerkleAccount alias only. Modules: the alias and the Safe itself. |
| `RecipeCapability`             | Stateless. The Safe delegatecalls it for recipes.                            |
| `ThreeFPolicy` and its factory | Bound to and owned by the Safe. Uses 3F's Base RequestFactory and Facility.  |

External addresses are in [BaseChain.sol](../../base-chain/BaseChain.sol). Each one was checked onchain.

## 1. Deploy on Base

```sh
export BASE_MANIFEST=deployments/base-safe.json
export BASE_ETHEREUM_ACCOUNT=0x...   # Ethereum MerkleAccount
export BASE_SAFE_SALT_NONCE=0
export BASE_FACTORIES_OWNER=0x...    # whitelists future ThreeFPolicy versions; the alias keeps this on Ethereum
mkdir -p deployments

forge script script/deploy/base-chain/DeployBaseSafe.s.sol:DeployBaseSafeScript \
  --rpc-url "$BASE_RPC_URL" --account base-deployer
```

Add `--broadcast` to send. The deployer owns the Safe only until the configuration transaction. That transaction
enables both modules, makes the alias the only owner and removes the deployer. Before writing the manifest, the
script checks the owner, threshold, modules and policy binding. It refuses to overwrite a manifest. A dry run (no `--broadcast`)
writes no manifest, so the broadcast run that follows can write it.

## 2. Add the leaves to the Ethereum root

```sh
BASE_MANIFEST=deployments/base-safe.json BASE_LEAVES=deployments/base-safe-leaves.json \
  forge script script/actions/base-chain/BuildBaseChainLeaves.s.sol:BuildBaseChainLeavesScript
```

The leaves file lists each action's target, calldata template, mask and leaf hash:

| Leaf                      | Chain run on | Free words                       | Grant to         |
| ------------------------- | ------------ | -------------------------------- | ---------------- |
| `approveBridge`           | Ethereum     | amount                           | executor         |
| `bridgeToBase`            | Ethereum     | amount                           | executor         |
| `bridgeToEthereum`        | Base         | amount                           | executor         |
| `mintThreeF`              | Base         | request, principal cap           | trusted executor |
| `redeemThreeF`            | Base         | request                          | executor         |
| `setMaxAssetsPerDuration` | Base         | underlying asset, budget, window | curator          |
| `setMinYieldPerRequest`   | Base         | underlying asset, minimum        | curator          |

A one-time ERC-1271 message, such as 3F's `EnrollMaker`, gets its own leaf with the digest pinned:

```sh
BASE_MANIFEST=deployments/base-safe.json BASE_MESSAGE_DIGEST=0x... \
  BASE_MESSAGE_LEAF=deployments/base-safe-enroll-maker.json \
  forge script script/actions/base-chain/BuildMessageLeaf.s.sol:BuildMessageLeafScript
```

The file also records the signature to give the verifier after the approval runs on Base.

Then:

1. Add the leaves to the MerkleAccount's tree and publish the root in `RootRegistry`.
2. Accept the root on the account, and grant each leaf role to its executor.
3. Write the proofs file that the action scripts read: a JSON object keyed by leaf hash.

```json
{ "0x<leaf>": ["0x<sibling>", "..."] }
```

## 3. Run actions from Ethereum

Edit the constants at the top of each script. Then run it on Ethereum with the executor that holds the leaf role.

| Script                           | Effect                                                                     |
| -------------------------------- | -------------------------------------------------------------------------- |
| `BridgeUsdcToBase.s.sol`         | Approves and burns MerkleAccount USDC to the Safe.                         |
| `SetThreeFMaxAssetsOnBase.s.sol` | Sets the policy's USDC budget for a 3F underlying asset.                   |
| `SetThreeFMinYieldOnBase.s.sol`  | Sets the policy's minimum yield for a 3F underlying asset.                 |
| `MintThreeFOnBase.s.sol`         | Charges the policy, then mints into a 3F request that authorized the Safe. |
| `RedeemThreeFOnBase.s.sol`       | Redeems the Safe's position in a repaid 3F request.                        |
| `BridgeUsdcToEthereum.s.sol`     | Burns Safe USDC back to the MerkleAccount.                                 |
| `ReceiveCctpMessage.s.sol`       | Relays an attested CCTP message on the destination chain.                  |
| `ApproveMessageOnBase.s.sol`     | Makes the Safe accept one pinned ERC-1271 digest.                          |

```sh
forge script script/actions/base-chain/BridgeUsdcToBase.s.sol:BridgeUsdcToBaseScript \
  --rpc-url "$ETH_RPC_URL" --account executor --broadcast
```

For a mint, set `MAX_ASSETS` to the principal of the accepted offer. The recipe reads `mintAuthorization(safe)` on
Base when it runs, and reverts if the authorization is zero or above `MAX_ASSETS`. The policy rejects a mint until
`SetThreeFMaxAssetsOnBase` has set a budget for the request's underlying asset.

After a CCTP burn, wait until Circle's API returns the message with status `complete`. Query
`https://iris-api.circle.com/v2/messages/<sourceDomain>?transactionHash=<burnTx>`; Ethereum is domain 0 and Base
is domain 6. Then put `message` and `attestation` into `ReceiveCctpMessage.s.sol` and run it on the destination chain.
Anyone can relay.

## Operating notes

- **A Base action can fail without reverting on Ethereum.** A portal deposit lands on Base a few minutes after the
  Ethereum transaction. If the Safe call fails, the Safe returns false and emits `ExecutionFromModuleFailure`. The
  deposit still succeeds and cannot be retried, so monitor the Safe's module events and resend from Ethereum.
- **Each leaf pins its L2 gas limit**, `BaseChain.PORTAL_GAS_LIMIT` (1,000,000). Changing it changes every portal
  leaf.
- **The 3F recipes take the request from one input.** Recipe call targets are literal, so the Safe calls the request
  through itself (`execTransactionFromModule(request, 0, data, CALL)`, the Safe being its own module). A module call
  returns false instead of reverting, so each recipe checks the result: the mint checks that the Safe's USDC fell by
  exactly the principal, and the redeem checks that the Safe holds no PT or YT afterwards.
- **`mintThreeF` reads the authorization on Base.** A stale or revoked authorization reverts the recipe before the
  policy is charged. The policy checks the request against 3F's factory and Facility, and the redeem checks it against
  the factory. Grant the mint leaf only to a trusted executor.
- **ERC-1271 messages are pinned, one leaf per digest.** The alias approves the Safe message hash with
  `Safe.approveHash`, and the Safe then accepts the approved-hash signature (alias as `r`, `v` = 1) for that digest
  only. Never add a leaf with a free digest: an executor could then sign a USDC permit.
- **No key on Base controls the Safe.** Every action and every admin change, such as swapping a module or migrating
  the policy, needs a leaf in the Ethereum root. To add an action, add a recipe or leaf through the usual root
  process.
- **Before migrating the Ethereum MerkleAccount, move the Safe to the new alias.** The alias is derived from the
  account address. Add and run a leaf that adds the new alias as owner and module and removes the old one. Otherwise
  the Safe can no longer be controlled.

## Tests

`test/deploy/BaseSafePayloads.t.sol` checks the leaf masks, the nesting and the proof flow. `test/deploy/DeployBaseSafe.t.sol`
deploys on a Base fork and replays the alias calls within the pinned gas limit. It also sends the portal deposit and
the USDC burn on an Ethereum fork. Set `BASE_RPC_URL` and `ETH_RPC_URL` to run the fork tests.
