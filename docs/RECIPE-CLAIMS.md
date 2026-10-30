# Claims after settlement

`ClaimRecipe` commits one unconditional managed claim and its permitted leaves.
The caller prepares the ready request ID, amount and proof. The recipe has no
queries, numeric inputs, readiness logic, amount caps or payout-floor assertions.
The account still verifies the active permission, caller role, target, recipient
and every unmasked calldata byte. The issuer verifies eligibility and computes
its payout.

Use the same executor for every ready request. Encode one `execute` call per
request, then pass these calls to `RecipeExecutor.multicall(bytes[])`. Multicall
preserves the authorized caller and reverts the whole batch if any claim fails.
The SDK discovers requests at one pinned block and simulates the complete batch
before submission; simulation does not reserve liquidity or guarantee inclusion.
A bounded batch can be followed by another scan/execution.

Claims and repayment are separate automations. Claiming leaves proceeds in the
account. Run `health-repay` separately to repay from available account cash under
its configured reserve, repayment cap and target health.

## Discovery and ordering

Discovery belongs to the executor SDK, not a deployed contract. It uses owner
ledgers for Noon and Pareto, ERC-7540 claimable/max getters for aggregate vault
claims and cancellation refunds, OpenEden escrow balances and 3F factory-attested
request contracts. Merkl supplies a proof witness for the cumulative distributor
claim. Midas mint and redemption settlements push assets to their recipient and
have no separate holder claim operation.

Reviewed ordering behavior:

| Integration           | Claim effect                                                                                     | Oldest-first required?                           |
| --------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| Noon                  | Marks only `withdrawalRequests[msg.sender][requestId]` claimed.                                  | No.                                              |
| Pareto queue          | Clears only the selected owner's epoch deposit/withdrawal entry.                                 | No.                                              |
| Pareto direct         | Clears the owner's aggregate claim for that path.                                                | No separate IDs.                                 |
| ERC-7540 / Centrifuge | Decreases aggregate claimable shares/assets; refund claims clear their own cancellation balance. | No caller-selected newer request.                |
| OpenEden              | Clears the owner's token-specific deposit escrow or redemption escrow.                           | No separate IDs.                                 |
| 3F                    | Burns the owner's rights in that request contract. Other requests are independent.               | No.                                              |
| Merkl                 | Pays the difference between the cumulative proven amount and previously claimed amount.          | Newer cumulative proofs include earlier rewards. |

No reviewed claim requires a recipe-level oldest-first guard to preserve older
rights. Queue processing order imposed on an issuer is distinct from the holder's
claim order. The SDK processes numbered candidates in ascending order anyway;
changing the selected request does not expand its permission.

Sources: [Noon WithdrawalHandler](https://etherscan.io/address/0x0dabc0d9b270c9b0c4c77aaceaa712b56d0f9178#code),
[Pareto queue](https://github.com/Idle-Labs/idle-tranches/blob/a3cc2e5696c634b52e7907a8587692365aefe8e0/contracts/IdleCDOEpochQueue.sol),
[Centrifuge request manager](https://github.com/centrifuge/protocol/blob/6b9d36eabee48728486f377ea2766a5cd233c555/src/vaults/AsyncRequestManager.sol),
[Merkl distributor](https://github.com/AngleProtocol/merkl-contracts/blob/ed53c6940c1827f9146c3a4222839ff7bc37a2ab/contracts/Distributor.sol).
These source checks establish claim semantics, not live account eligibility.
