# Recipe examples and readable manifests

`ll-cooldown.json` retains purchased RWA while creating a cooldown entitlement.
`lending-async.json` checks queued subscription shares and uses a later `claim` run.
`claim-bounded.json` limits each selected claim per execution, and
`health-claim-ready.json` omits the pending read for an issuer that moves pending
principal into claimable principal at settlement.
`claim-conditional.json` shows two independent groups, including a valid request ID
of zero. Every claim recipe lets a keeper wait after successful all-empty
simulation; a manual invocation can succeed without work.

The root JSON files in this directory are illustrative recipe configurations. Their
addresses, leaves and economic limits must be replaced and verified before use.

`claim.json` collects ready redemptions, withdrawals, mints or rewards independently
after settlement. `health-repay.json` repays already-held cash above an explicit
reserve, including payouts that arrived in earlier transactions. See
[Claims after settlement](../../../docs/RECIPE-CLAIMS.md) for units and runtime payloads.

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

Regenerate all samples with Foundry 1.8.5:

```sh
UPDATE_RECIPE_MANIFESTS=true forge test --offline --match-contract '^(RecipeManifestBuildTest|RecipeManifestTest)$' --gas-snapshot-emit false
```

Remove `UPDATE_RECIPE_MANIFESTS=true` to check the committed samples without updating
them. The test discovers every direct `*.json` configuration in this directory,
builds it, and compares the manifest's hash, opcodes, queries and runtime slots with
the encoded recipe. New example configurations automatically require a matching
sample; update the isolated mock setup if a new template needs protocol resolution.
