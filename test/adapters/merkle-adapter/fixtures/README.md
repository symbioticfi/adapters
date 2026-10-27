# Curator ERC-7540 fixture

`erc7540-curator.json` contains encoded programs and execution payloads generated
by `curator-frontend`'s `erc7540-vault.test.ts`. Addresses are fixed test identities;
the Foundry test installs local token/vault fixtures at those addresses. No
mainnet deployment or settlement is represented.

Generate the complete source fixture in the frontend checkout:

```sh
ERC7540_WRITE_FIXTURE=/tmp/erc7540-full.json pnpm exec vitest run \
  src/shared/lib/merkle/operations/authoring/catalog/types/erc7540-vault.test.ts
```

Keep `account`, `vault`, `asset`, `set.root` as `root`, and each `set.calls[].hash`
as `leaves`. For every `recipes` entry keep `recipe`, `recipeHash` and
`executionRuntime`. The Solidity test consumes these bytes unchanged and checks
their hashes, leaf proofs, live claim amounts, approval cleanup and pinned
recipients.
