# Mainnet token oracles

Each asset has its own no-argument contract in
`src/contracts/merkle-adapter/connectors/oracles/tokens/`. The contracts fix the
source and bounds in their constructors and inherit the existing pricing logic.
Deployments replace the configured oracle address; existing deployed contracts remain immutable.

## Reference and bounds

The catalogue was captured from finalized Ethereum block **26355737**
(`0xd15d184066ab904eb56c2177e9afbd3dddbe35adb3a956422a1a9bb03d344ab7`),
**2026-11-06T12:13:11+00:00**.
Prices are payment tokens per whole asset, normalized to `1e18`; BTC-denominated
Midas products keep their native payment token rather than becoming USD quotes.

- The 15 reused LL oracles retain their deployed address, exact bounds and source.
  Their token contracts extract the same constructor configuration; deployment
  reuses the live oracle rather than deploying the wrapper again.
- HYBOND quotes the gross second return value of `previewRedeem`, before the
  express redemption fee. TBILL likewise uses the pre-fee `previewRedeem` value.
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

The mainnet catalogue now reuses **40** deployed addresses. Only the three
BTC-denominated Midas entries remain undeployed. The deployment script does not
register oracles, modify any connector, or update application configuration.
The resulting address map is written to `deployments/token-oracles-mainnet.json`;
set `TOKEN_ORACLES_OUTPUT` to choose another file. Set `TOKEN_ORACLES_CONFIG` to
a filtered catalogue to deploy a selected subset. Use Foundry's `--resume` for
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
live prices, bounds and source getters at the reference block. Oracles deployed
after that block are recreated and checked against their captured price and
percentage-derived bounds.

## November 9 deployment

The 25 requested USDC-quoted oracles were deployed with `testnet-deployer`,
including the net-redemption HYBOND replacement. See the
[deployment receipt and address map](../script/deploy/oracles/mainnet-deployment.json).
`mainnet.json` reuses these addresses on subsequent deployments.

RFQ frontend and backend store the token-to-oracle mappings. Curator reads
`OracleRegistry.oracles(connector, token)`; NAV reads issuer sources directly.
Neither needs a duplicate connector-oracle address table. Registry approvals
remain per connector and must be set by the registry owner; deploying an oracle
does not install it for every connector.

## November 12 gross-price replacement

HYBOND was redeployed with `mainnet-deployer` to use the gross second return of
OpenEden Express `previewRedeem`, before the redemption fee. The same change is
applied to the legacy LL oracle implementation. Its source address and the
25% / 350% range policy remain unchanged; the bounds use the gross reference
price at block 26355737.

The new oracle is [0x6652c86c70Ba8A621DD441213eB600c4353136af](https://etherscan.io/address/0x6652c86c70Ba8A621DD441213eB600c4353136af#code).
See the [deployment and price-check record](../script/deploy/oracles/hybond-gross-mainnet-deployment.json).
The November 9 receipt remains historical. TBILL already prices before fees and
is reused. Existing legacy LL accounts retain their immutable oracle until an
account implementation migration; changing the RFQ mapping does not migrate them.

| Contract                              | Status   |     Minimum (1e18) |      Maximum (1e18) |
| ------------------------------------- | -------- | -----------------: | ------------------: |
| `AA_AdaptiveFrontier_Oracle`          | Deployed | 280218000000000000 | 3923052000000000000 |
| `AA_Bastion_Oracle`                   | Deployed | 293568750000000000 | 4109962500000000000 |
| `AA_FalconX_Oracle`                   | Reuse    | 275519750000000000 | 3857276500000000000 |
| `AA_Fasanara_Oracle`                  | Deployed | 299080750000000000 | 4187130500000000000 |
| `AA_RockawayX_Oracle`                 | Deployed | 276059750000000000 | 3864836500000000000 |
| `ACRDX_Oracle`                        | Deployed | 255565750000000000 | 3577920500000000000 |
| `AUTO_Oracle`                         | Deployed | 257828000000000000 | 3609592000000000000 |
| `CarryTradeUSDTRYLeverage_Oracle`     | Reuse    | 261000000000000000 | 3653400000000000000 |
| `deJAAA_Oracle`                       | Reuse    | 260037000000000000 | 3640518000000000000 |
| `deJTRSY_Oracle`                      | Reuse    | 257864500000000000 | 3610103000000000000 |
| `HYB_Oracle`                          | Reuse    | 250943250000000000 | 3513205500000000000 |
| `HYBOND_Oracle`                       | Replaced | 433949250000000000 | 6075289500000000000 |
| `JAAA_Oracle`                         | Reuse    | 260413500000000000 | 3645789000000000000 |
| `JTRSY_Oracle`                        | Reuse    | 277562500000000000 | 3885875000000000000 |
| `mAPOLLO_Oracle`                      | Deployed | 282487232500000000 | 3954821255000000000 |
| `mBASIS_Oracle`                       | Deployed | 306000955000000000 | 4284013370000000000 |
| `mBTC_Oracle`                         | New      | 516201565000000000 | 2064806260000000000 |
| `mEDGE_Oracle`                        | Deployed | 288504705000000000 | 4039065870000000000 |
| `mFONE_Oracle`                        | Reuse    | 275900000000000000 | 3862200000000000000 |
| `mGLO_Oracle`                         | Reuse    | 251441200000000000 | 3520176800000000000 |
| `mGLOBAL_Oracle`                      | Reuse    | 251441200000000000 | 3520176800000000000 |
| `mHYPER_Oracle`                       | Reuse    | 277200000000000000 | 3880300000000000000 |
| `mHyperBTC_Oracle`                    | New      | 514580010000000000 | 2058320040000000000 |
| `mM1USD_Oracle`                       | Reuse    | 253500000000000000 | 3548800000000000000 |
| `mRe7BTC_Oracle`                      | New      | 498394385000000000 | 1993577540000000000 |
| `mRe7YIELD_Oracle`                    | Deployed | 270878517500000000 | 3792299245000000000 |
| `mROX_Oracle`                         | Reuse    | 282900000000000000 | 3961200000000000000 |
| `mSL_Oracle`                          | Deployed | 584574835000000000 | 2338299340000000000 |
| `msyrupUSD_Oracle`                    | Deployed | 509226070000000000 | 2036904280000000000 |
| `msyrupUSDp_Oracle`                   | Deployed | 265318172500000000 | 3714454415000000000 |
| `mTBILL_Oracle`                       | Deployed | 269342190000000000 | 3770790660000000000 |
| `PRIME_Oracle`                        | Reuse    | 262415750000000000 | 3673820500000000000 |
| `StockMarketTRBasisTrade_Oracle`      | Reuse    | 253000000000000000 | 3541400000000000000 |
| `sUSN_Oracle`                         | Deployed | 617390000000000000 | 3086950000000000000 |
| `TBILL_Oracle`                        | Deployed | 290662750000000000 | 4069278500000000000 |
| `gamiUSDC_Oracle`                     | Deployed | 275397000000000000 | 3855558000000000000 |
| `tulipaUSDC_Oracle`                   | Deployed | 267825000000000000 | 3749550000000000000 |
| `NineSummitsUSDC_Oracle`              | Deployed | 294302750000000000 | 4120238500000000000 |
| `MtPoolUSD_Oracle`                    | Deployed | 260903500000000000 | 3652649000000000000 |
| `NineSummitsInstitutionalUSDC_Oracle` | Deployed | 254371750000000000 | 3561204500000000000 |
| `flUSD_Oracle`                        | Deployed | 250469250000000000 | 3506569500000000000 |
| `USDst_Oracle`                        | Deployed | 251371750000000000 | 3519204500000000000 |
| `USDtest_Oracle`                      | Deployed | 251291500000000000 | 3518081000000000000 |
