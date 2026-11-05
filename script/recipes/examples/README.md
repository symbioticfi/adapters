# Recipe examples and readable manifests

`ll-cooldown.json` retains purchased RWA while creating a cooldown entitlement.
`lending-async.json` checks queued subscription shares and uses a later `claim` run.
`claim-runtime.json` takes request identifiers from the executor.
All claim recipes perform no reads; amounts and proofs also come from the executor.
The executor selects ready claims and batches independent executions.

`3f-executing.json` selects canonical native mint authorization through live helper reads. The guarded leaf lets the policy select the request collateral budget dynamically. `resetApproval` defaults to `true`; set it to `false` only for a funding token known to support direct nonzero approvals on the configured chain. The frontend approval-policy allowlist applies only to mainnet; unknown tokens and other chains require reset.


3F claims use a reusable factory-checked RecipeCapability leaf with a runtime request, as described in [Claims after settlement](../../../docs/RECIPE-CLAIMS.md). Do not grant a direct burn permission for each request.

The root JSON files in this directory are illustrative recipe configurations. Their
addresses, leaves and economic limits must be replaced and verified before use.

`claim.json` collects ready redemptions, withdrawals, mints or rewards independently
after settlement. `health-repay.json` repays available account cash, including payouts that arrived in earlier transactions. See
[Claims after settlement](../../../docs/RECIPE-CLAIMS.md) for units and runtime payloads.

`signing.json` signs an oracle-bounded CoW order and sets the sell-token allowance
to the signed amount, which caps outstanding settlement exposure. See
[Bounded signing recipes](../../../docs/RECIPE-SIGNING.md).

`withdrawals.json` covers the vault queue's live demand from account cash, then an
ERC-4626 withdrawal and an Aave withdrawal skipped while that pool has debt, and
returns the covered amount to the adapter.

`manifests/` contains a readable sample for every configuration. Each sample includes
the recipe hash, encoded query calls, instruction operands, runtime slots and required
opcodes. The 3F sample also includes `guardedMintManifest`, decoded from the guarded
mint leaf's nested recipe. `recipe` and optional `guardedRecipe` contain the exact
encoded programs for consumers to verify decoding and hash consistency across
Solidity, TypeScript and Go. `fixtures/all-opcodes.json` adds a decoder corpus for
all 12 supported operation numbers and full-width operand references. It describes symbolic calls
and bindings for testing the encoding, rather than an executable automation.
Guarded examples also have a complete build output under `fixtures/`, including
their nested calldata, masks and leaf hashes for import verification tests.

These samples use mock adapter and 3F protocol resolution, local chain ID `31337`,
block `1` and a zero parent block hash. They describe the dummy examples and are not
deployment evidence or live protocol snapshots. Production `BuildRecipe` outputs
record the actual build context instead.

Regenerate all samples with Foundry 1.8.1:

```sh
UPDATE_RECIPE_MANIFESTS=true forge test --offline --match-contract '^(RecipeManifestBuildTest|RecipeManifestTest)$' --gas-snapshot-emit false
```

Remove `UPDATE_RECIPE_MANIFESTS=true` to check the committed samples without updating
them. The test discovers every direct `*.json` configuration in this directory,
builds it, and compares the manifest's hash, opcodes, queries and runtime slots with
the encoded recipe. New example configurations automatically require a matching
sample; update the isolated mock setup if a new template needs protocol resolution.
