# Bounded signing recipes

`SigningRecipe` compiles a native `MerkleAccount.sign` authorization into an
executor program. `BuildRecipe` accepts `"template": "signing"` and writes the
recipe, `signData`, `signMask` and `signLeaf`. Grant that leaf role to the executor;
the provider calls the executor. Giving the provider the raw sign leaf role lets
it skip the recipe checks.

Execution inputs are `[amountIn, minimumAmountOut, deadline]`, plus `nonce` when
configured. Amounts use raw token units. The committed program checks:

- `minAmount <= amountIn <= maxAmount`.
- A positive price from the configured oracle query.
- `quote = floor(amountIn * price / priceDenominator)` and
  `minimumAmountOut >= quote - floor(quote * slippageBps / 10000)`.
- A positive output floor, so rounding cannot authorize a zero-value sale.
- `now <= deadline <= now + maxDuration`, using the configured clock query.
- CoW's deadline fits `uint32` when `deadlineBytes` is `4`.

`slippageBps` is a predefined literal in the recipe, never a provider input.
The oracle must return the price for the fixed input/output pair and reject stale
or invalid observations. The clock must return `block.timestamp` from a trusted
contract, such as Multicall3's `getCurrentBlockTimestamp()`. Neither query may
take its observation from provider inputs. Price and time are read during signing;
the protocol subsequently enforces the signed price floor and deadline.

For an oracle returning an 18-decimal price in whole output tokens per whole input
token, set `priceDenominator = 10^(18 + inputDecimals - outputDecimals)`.
For example, 18-decimal RWA sold for 6-decimal USDC uses `1e30`. A price of `2e18`
and amount `100e18` gives `200e6` USDC before slippage. At 100 basis points, the
minimum is `198e6`. The initial quote rounds down by less than one output unit;
slippage rounding is conservative. Arithmetic overflow reverts.

Supply canonical ABI-encoded `sign(bytes32,bytes,Hash[])` calldata as `signData`,
including its fixed domain, typed fields and hashing plan. The compiler constructs
the mask itself, binds every masked word to a checked input, and fixes every other
byte. Select the actual economic fields of the protocol's encoding:

| Encoding                                                                   | Input offset | Output offset | Deadline offset | Deadline bytes | Nonce offset |
| -------------------------------------------------------------------------- | -----------: | ------------: | --------------: | -------------: | -----------: |
| CoW flat order, as in `MerkleAdapterCoWSignatures.t.sol`                   |          260 |           292 |             324 |              4 |      omitted |
| Liquid Lane single output, as in `MerkleAdapterLiquidLaneSignatures.t.sol` |          196 |           420 |             260 |             32 |          292 |

Offsets are calldata byte offsets including the selector. Keep the CoW fee zero,
the order kind and token balances fixed, and the receiver equal to the account.
For Liquid Lane, fix the input token, the single output token and recipient,
protocol, type hashes and complete hashing plan. Other encodings need verified
economic offsets and unit conversion before authorization.

The signing JSON uses the usual `curator`, `provider`, `adapter` and optional
`factory` fields, plus:

```json
{
  "template": "signing",
  "signData": "<complete ABI-encoded native sign calldata>",
  "price": { "target": "<oracle>", "data": "<price query calldata>", "offset": 0 },
  "clock": { "target": "<trusted clock>", "data": "<timestamp query calldata>", "offset": 0 },
  "limits": {
    "minAmount": "1000000000000000000",
    "maxAmount": "100000000000000000000",
    "priceDenominator": "1000000000000000000000000000000",
    "slippageBps": 100,
    "maxDuration": 300
  },
  "amountOffsets": { "input": 260, "output": 292, "deadline": 324 },
  "deadlineBytes": 4
}
```

Replace the placeholders, then build using the existing command:

```sh
forge script script/recipes/BuildRecipe.s.sol:BuildRecipe --rpc-url "$TESTNET_RPC_URL" --sig 'run(string,string)' signing.json out/signing.json
```

Use the emitted `signData` and `signMask` in the single runtime action, targeting
the canonical `adapter.account()`, with zero native value and its current proof.
The runtime's economic values are overwritten by the validated execution inputs.
The limits apply per authorization; they do not create an aggregate order budget.
