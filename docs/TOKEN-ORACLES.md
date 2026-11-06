# Mainnet token oracles

Each asset has its own no-argument contract in
`src/contracts/merkle-adapter/connectors/oracles/tokens/`. The contracts fix the
source and bounds in their constructors and inherit the existing pricing logic.
No protocol/account implementation or deployed contract is changed.

## Reference and bounds

The catalogue was captured from finalized Ethereum block **26355737**
(`0xd15d184066ab904eb56c2177e9afbd3dddbe35adb3a956422a1a9bb03d344ab7`),
**2026-11-06T12:13:11+00:00**.
Prices are payment tokens per whole asset, normalized to `1e18`; BTC/ETH-denominated
Midas products keep their native payment token rather than becoming USD quotes.

- The 15 reused LL oracles retain their deployed address, exact bounds and source.
  Their token contracts extract the same constructor configuration; deployment
  reuses the live oracle rather than deploying the wrapper again.
- HYBOND is deliberately replaced: it quotes the net third return value of
  `previewRedeem`, after the express redemption fee.
- New bounds are `floor(referencePrice * percentage / 100)`.
  The core LL deployment convention is 25% / 350% (75% loss / 250% growth).
  Midas assets whose core account uses 50% / 200% retain that convention;
  Noon retains its 50% / 250% convention. There is no unrestricted default range.
- Existing feed staleness, Pareto default handling and pricing logic remain in
  their protocol oracle implementations.

The exact reference prices, bounds, source addresses and reuse decisions are in
[`mainnet.json`](../script/deploy/oracles/mainnet.json).

## Deploy

From the adapters repository, using its pinned Foundry version:

```sh
forge script script/deploy/oracles/DeployTokenOracles.s.sol:DeployTokenOracles \
  --rpc-url "$ETH_RPC_URL" \
  --account "$DEPLOYER_ACCOUNT" \
  --broadcast \
  --verify
```

This deploys **34** new oracles and reuses **15** existing addresses. It does not
register oracles, modify any connector, or update any application configuration.
The resulting address map is written to `deployments/token-oracles-mainnet.json`;
set `TOKEN_ORACLES_OUTPUT` to choose another file. Use Foundry's `--resume` for
interrupted broadcasts rather than starting another deployment.

Run without `--broadcast --verify` to simulate first. A live source that is outside
the fixed range makes validation fail rather than silently widening the range.

## Validation

```sh
FOUNDRY_SRC=src/contracts/merkle-adapter/connectors/oracles \
FOUNDRY_TEST=test/adapters/merkle-adapter/connectors/oracles \
FOUNDRY_SCRIPT=script/deploy/oracles \
ETH_RPC_URL="$ETH_RPC_URL" \
forge test --match-contract TokenOraclesMainnetTest -vv
```

The fork tests recreate every token oracle. They compare preserved oracles against
live prices, bounds and source getters; new oracles must match the captured price
and percentage-derived bounds at the reference block.

| Contract                              | Status         |     Minimum (1e18) |      Maximum (1e18) |
| ------------------------------------- | -------------- | -----------------: | ------------------: |
| `AA_Abraxas_Oracle`                   | New            | 269646750000000000 | 3775054500000000000 |
| `AA_AdaptiveFrontier_Oracle`          | New            | 280218000000000000 | 3923052000000000000 |
| `AA_Bastion_Oracle`                   | New            | 293568750000000000 | 4109962500000000000 |
| `AA_FalconX_Oracle`                   | Reuse          | 275519750000000000 | 3857276500000000000 |
| `AA_Fasanara_Oracle`                  | New            | 299080750000000000 | 4187130500000000000 |
| `AA_RockawayX_Oracle`                 | New            | 276059750000000000 | 3864836500000000000 |
| `ACRDX_Oracle`                        | New            | 255565750000000000 | 3577920500000000000 |
| `AUTO_Oracle`                         | New            | 257828000000000000 | 3609592000000000000 |
| `CarryTradeUSDTRYLeverage_Oracle`     | Reuse          | 261000000000000000 | 3653400000000000000 |
| `deJAAA_Oracle`                       | Reuse          | 260037000000000000 | 3640518000000000000 |
| `deJTRSY_Oracle`                      | Reuse          | 257864500000000000 | 3610103000000000000 |
| `HYB_Oracle`                          | Reuse          | 250943250000000000 | 3513205500000000000 |
| `HYBOND_Oracle`                       | Replace HYBOND | 433515500000000000 | 6069217000000000000 |
| `JAAA_Oracle`                         | Reuse          | 260413500000000000 | 3645789000000000000 |
| `JTRSY_Oracle`                        | Reuse          | 277562500000000000 | 3885875000000000000 |
| `mAPOLLO_Oracle`                      | New            | 282487232500000000 | 3954821255000000000 |
| `mBASIS_Oracle`                       | New            | 306000955000000000 | 4284013370000000000 |
| `mBTC_Oracle`                         | New            | 516201565000000000 | 2064806260000000000 |
| `mEDGE_Oracle`                        | New            | 288504705000000000 | 4039065870000000000 |
| `mevBTC_Oracle`                       | New            | 511811155000000000 | 2047244620000000000 |
| `mEVUSD_Oracle`                       | New            | 522689035000000000 | 2090756140000000000 |
| `mFARM_Oracle`                        | New            | 506302310000000000 | 2025209240000000000 |
| `mFONE_Oracle`                        | Reuse          | 275900000000000000 | 3862200000000000000 |
| `mGLO_Oracle`                         | Reuse          | 251441200000000000 | 3520176800000000000 |
| `mGLOBAL_Oracle`                      | Reuse          | 251441200000000000 | 3520176800000000000 |
| `mHYPER_Oracle`                       | Reuse          | 277200000000000000 | 3880300000000000000 |
| `mHyperBTC_Oracle`                    | New            | 514580010000000000 | 2058320040000000000 |
| `mHyperETH_Oracle`                    | New            | 509483145000000000 | 2037932580000000000 |
| `mM1USD_Oracle`                       | Reuse          | 253500000000000000 | 3548800000000000000 |
| `mMEV_Oracle`                         | New            | 289842047500000000 | 4057788665000000000 |
| `mRe7BTC_Oracle`                      | New            | 498394385000000000 | 1993577540000000000 |
| `mRe7YIELD_Oracle`                    | New            | 270878517500000000 | 3792299245000000000 |
| `mROX_Oracle`                         | Reuse          | 282900000000000000 | 3961200000000000000 |
| `mSL_Oracle`                          | New            | 584574835000000000 | 2338299340000000000 |
| `msyrupUSD_Oracle`                    | New            | 509226070000000000 | 2036904280000000000 |
| `msyrupUSDp_Oracle`                   | New            | 265318172500000000 | 3714454415000000000 |
| `mTBILL_Oracle`                       | New            | 269342190000000000 | 3770790660000000000 |
| `PRIME_Oracle`                        | Reuse          | 262415750000000000 | 3673820500000000000 |
| `StockMarketTRBasisTrade_Oracle`      | Reuse          | 253000000000000000 | 3541400000000000000 |
| `sUSN_Oracle`                         | New            | 617390000000000000 | 3086950000000000000 |
| `TBILL_Oracle`                        | New            | 290662750000000000 | 4069278500000000000 |
| `gamiUSDC_Oracle`                     | New            | 275397000000000000 | 3855558000000000000 |
| `tulipaUSDC_Oracle`                   | New            | 267825000000000000 | 3749550000000000000 |
| `NineSummitsUSDC_Oracle`              | New            | 294302750000000000 | 4120238500000000000 |
| `MtPoolUSD_Oracle`                    | New            | 260903500000000000 | 3652649000000000000 |
| `NineSummitsInstitutionalUSDC_Oracle` | New            | 254371750000000000 | 3561204500000000000 |
| `flUSD_Oracle`                        | New            | 250469250000000000 | 3506569500000000000 |
| `USDst_Oracle`                        | New            | 251371750000000000 | 3519204500000000000 |
| `USDtest_Oracle`                      | New            | 251291500000000000 | 3518081000000000000 |
