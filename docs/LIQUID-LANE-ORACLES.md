# Liquid Lane oracle coverage

The connector's `getAmountOut` treats `IOracle.getPrice()` as payment tokens per whole purchased token, scaled to `1e18`. It does not perform FX conversion. Token decimals are applied separately by the connector. An oracle quoting BTC, ETH or USN must not be installed directly on a USDC connector.

## Composition

`CompositeOracle` calculates `source * conversion / quote`, flooring each fixed-point operation with `Math.mulDiv`. All three inputs use `IOracle` and 18-decimal prices. A zero conversion or quote address means an identity factor. The source is mandatory. All source failures and configured bounds propagate; a zero denominator is rejected.

For a Midas USD-denominated feed paid in USDC, use `CompositeOracle(midas, zero, usdcUsd)`. BTC/ETH-denominated products are bought only with their supported BTC/ETH redemption assets and use `MidasOracle` directly. They are not configured for USDC purchases. The issuer marks these payment assets with a 1:1 native-currency rate (`tokensConfig(...).stable`); the coverage test checks this binding. Feed descriptions alone are insufficient to establish denomination: for example, the mBTC feed says USD while the product and redemption configuration use BTC units.

| Product   | Tested payment asset | Oracle        |
| --------- | -------------------- | ------------- |
| mBTC      | tBTC                 | `MidasOracle` |
| mEVBTC    | WBTC                 | `MidasOracle` |
| mHYPERBTC | cbBTC                | `MidasOracle` |
| mRE7BTC   | WBTC                 | `MidasOracle` |
| mHYPERETH | WETH                 | `MidasOracle` |

Each connector's `outputAsset` must match its payment asset. Additional BTC redemption assets can use the same native quote only when their issuer configuration also admits them at the 1:1 native-currency rate. Token decimals are normalized by `LiquidLaneConnector.getAmountOut`.

Centrifuge, Pareto, Hastra and the eight Lagoon vaults below already quote USDC. `NoonRateProviderOracle` quotes sUSN in USN; `NoonOracle` instead applies `convertToAssets` followed by the handler's `calculateCollateralAmount` for the selected payment collateral. TBILL uses `underlying` and `previewRedeem`, so it needs `OpenEdenTBILLOracle` rather than the HYBOND express oracle or ERC-4626 interface.

Prices represent the source's published mark, not guaranteed liquidation proceeds. Lagoon/Centrifuge conversions, TBILL preview and HYBOND's gross express preview use NAV before redemption fees. Midas keeps the configured execution feed, including its published markdown. Bounds, source choice and freshness windows must be reviewed when deploying each instance; the test's wide bounds are not production settings.

## Verified mainnet inventory

The source bindings and exact prices were captured at block **26354796** and are replayed by `OracleCoverageMainnetTest`. It deploys the actual oracle bytecode on the fork and checks all 49 assets, in their configured payment assets. USN and wYLDS are conversion dependencies, not purchase entries. Receipt-only claims are not ERC-20 purchase assets.

| Asset                                                                                             | Oracle                | Source                                                                                   | Native quote |
| ------------------------------------------------------------------------------------------------- | --------------------- | ---------------------------------------------------------------------------------------- | ------------ |
| [aa_abraxas](https://etherscan.io/token/0x6dbdeef7a188beaffc2c57006e5d8edaf0c0e9e6)               | `ParetoOracle`        | [0x0ad21c…fa32](https://etherscan.io/address/0x0ad21c3ac4ffe7c1ed2b1b717cd051ded365fa32) | USDC         |
| [aa_adaptivefrontier](https://etherscan.io/token/0xae7913c672c7f1f76c2a1a0ac4de97d082681234)      | `ParetoOracle`        | [0x14b8e9…46e0](https://etherscan.io/address/0x14b8e918848349d1e71e806a52c13d4e0d3246e0) | USDC         |
| [aa_bastion](https://etherscan.io/token/0xc49b4ecc14aa31ef0ad077edcf53fab4201b724c)               | `ParetoOracle`        | [0x4462ed…d165](https://etherscan.io/address/0x4462ed748b8f7985a4ac6b538dfc105fce2dd165) | USDC         |
| [aa_falconxusdc](https://etherscan.io/token/0xc26a6fa2c37b38e549a4a1807543801db684f99c)           | `ParetoOracle`        | [0x433d5b…be4d](https://etherscan.io/address/0x433d5b175148da32ffe1e1a37a939e1b7e79be4d) | USDC         |
| [aa_fasanara](https://etherscan.io/token/0x45054c6753b4bce40c5d54418dabc20b070f85be)              | `ParetoOracle`        | [0xf6223c…c2d5](https://etherscan.io/address/0xf6223c567f21e33e859ed7a045773526e9e3c2d5) | USDC         |
| [aa_rockawayx](https://etherscan.io/token/0xec6a70f62a83418c7fb238182ed2865f80491a8b)             | `ParetoOracle`        | [0x9cf358…0ec3](https://etherscan.io/address/0x9cf358aff79dea96070a85f00c0ac79569970ec3) | USDC         |
| [acrdx](https://etherscan.io/token/0x9477724bb54ad5417de8baff29e59df3fb4da74f)                    | `AsyncRedeemOracle`   | [0x74A739…B712](https://etherscan.io/address/0x74A739EA1Dc67c5a0179ebad665D1D3c4b80B712) | USDC         |
| [auto](https://etherscan.io/token/0x997e2efbce91d170b00ea402e35a66c887ee1da9)                     | `FigureOracle`        | [0x997e2e…1da9](https://etherscan.io/address/0x997e2efbce91d170b00ea402e35a66c887ee1da9) | USDC         |
| [carrytradeusdtryleverage](https://etherscan.io/token/0x2bf11d2e04bc40daa95c24b8b90ec4f5c57dd326) | `MidasOracle`         | [0xE65F08…8E79](https://etherscan.io/address/0xE65F08D9D0b010965d69253769A33511b72d8E79) | USD          |
| [dejaaa](https://etherscan.io/token/0xaaa0008c8cf3a7dca931adaf04336a5d808c82cc)                   | `AsyncRedeemOracle`   | [0x4865BC…4c9c](https://etherscan.io/address/0x4865BC9701fBD1207A7B50e2aF442C7DAf154c9c) | USDC         |
| [dejtrsy](https://etherscan.io/token/0xa6233014b9b7aaa74f38fa1977ffc7a89642dc72)                  | `AsyncRedeemOracle`   | [0x18Ab9f…8257](https://etherscan.io/address/0x18Ab9fC0B2e4Fef9e0e03c8EC63BA287a3238257) | USDC         |
| [hyb](https://etherscan.io/token/0x4827c7ecce4f07adfe44a97165f06a199e7d2505)                      | `AsyncRedeemOracle`   | [0xFeb5A9…A85a](https://etherscan.io/address/0xFeb5A9D7ADBbA65168B0FaBA90675F7c96fcA85a) | USDC         |
| [hybond](https://etherscan.io/token/0x1204371ac0e5176f4b8c5b2f16c2bec491b6fc1a)                   | `OpenEdenOracle`      | [0xd84c25…e569](https://etherscan.io/address/0xd84c2571e05a59108ead1c600d16133f0710e569) | USDC         |
| [jaaa](https://etherscan.io/token/0x5a0f93d040de44e78f251b03c43be9cf317dcf64)                     | `AsyncRedeemOracle`   | [0x488079…780B](https://etherscan.io/address/0x4880799eE5200fC58DA299e965df644fBf46780B) | USDC         |
| [jtrsy](https://etherscan.io/token/0x8c213ee79581ff4984583c6a801e5263418c4b86)                    | `AsyncRedeemOracle`   | [0xFE6920…d77A](https://etherscan.io/address/0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A) | USDC         |
| [mapollo](https://etherscan.io/token/0x7cf9dec92ca9fd46f8d86e7798b72624bc116c05)                  | `MidasOracle`         | [0x9aEBf5…D358](https://etherscan.io/address/0x9aEBf5d6F9411BAc349021ddFbe9B2c756BDD358) | USD          |
| [mbasis](https://etherscan.io/token/0x2a8c22e3b10036f3aef5875d04f8441d4188b656)                   | `MidasOracle`         | [0x1615cB…76e4](https://etherscan.io/address/0x1615cBC603192ae8A9FF20E98dd0e40a405d76e4) | USD          |
| [mbtc](https://etherscan.io/token/0x007115416ab6c266329a03b09a8aa39ac2ef7d9d)                     | `MidasOracle`         | [0x9987BE…E28e](https://etherscan.io/address/0x9987BE0c1dc5Cd284a4D766f4B5feB4F3cb3E28e) | BTC          |
| [medge](https://etherscan.io/token/0xbb51e2a15a9158ebe2b0ceb8678511e063ab7a49)                    | `MidasOracle`         | [0x20cd58…91cB](https://etherscan.io/address/0x20cd58F72cF1727a2937eB1816593390cf8d91cB) | USD          |
| [mevbtc](https://etherscan.io/token/0xb64c014307622eb15046c66ff71d04258f5963dc)                   | `MidasOracle`         | [0x568143…744f](https://etherscan.io/address/0x56814399caaEDCEE4F58D2e49DA058A81DDE744f) | BTC          |
| [mevusd](https://etherscan.io/token/0x548857309befb6fb6f20a9c5a56c9023d892785b)                   | `MidasOracle`         | [0x508Fe9…0fC9](https://etherscan.io/address/0x508Fe9496C7919E64406bB4042760d7Bb1F40fC9) | USD          |
| [mfarm](https://etherscan.io/token/0xa19f6e0df08a7917f2f8a33db66d0af31ff5eca6)                    | `MidasOracle`         | [0x9f49B0…9524](https://etherscan.io/address/0x9f49B0980B141b539e2A94Ec0864Faf699fF9524) | USD          |
| [mfone](https://etherscan.io/token/0x238a700ed6165261cf8b2e544ba797bc11e466ba)                    | `MidasOracle`         | [0xCF4e49…1C00](https://etherscan.io/address/0xCF4e49f5e750Af8F2f9Aa1642B68E5839D9c1C00) | USD          |
| [mglo](https://etherscan.io/token/0x1dd91a111606382b77a917633ed90feaf25e0f76)                     | `MidasOracle`         | [0x98bd3a…a963](https://etherscan.io/address/0x98bd3a24d3998EF96b12d896045EaCA7949Ea963) | USD          |
| [mglobal](https://etherscan.io/token/0x7433806912eae67919e66aea853d46fa0aef98a8)                  | `MidasOracle`         | [0xb468A6…139E](https://etherscan.io/address/0xb468A6F63868cB6C6D99105EDfbe73d6B21f139E) | USD          |
| [mhyper](https://etherscan.io/token/0x9b4928528656dbc094765e2abb79f293c21191b9)                   | `MidasOracle`         | [0x92004D…eCdE](https://etherscan.io/address/0x92004DCC5359eD67f287F32d12715A37916deCdE) | USD          |
| [mhyperbtc](https://etherscan.io/token/0xc8495eaff71d3a563b906295fcf2f685b1783085)                | `MidasOracle`         | [0xb75B82…3157](https://etherscan.io/address/0xb75B82b2012138815d1A2c4aB5B8b987da043157) | BTC          |
| [mhypereth](https://etherscan.io/token/0x5a42864b14c0c8241ef5ab62dae975b163a2e0c1)                | `MidasOracle`         | [0xbD560c…1EA2](https://etherscan.io/address/0xbD560c1E87752717C34912D128168BfE26021EA2) | ETH          |
| [mm1usd](https://etherscan.io/token/0xcc5c22c7a6bcc25e66726aef011dde74289ed203)                   | `MidasOracle`         | [0xF1aBD1…9279](https://etherscan.io/address/0xF1aBD1a4Fc5fa2848Cf3763FBE7B0DF366da9279) | USD          |
| [mmev](https://etherscan.io/token/0x030b69280892c888670edcdcd8b69fd8026a0bf3)                     | `MidasOracle`         | [0x9BF00b…e359](https://etherscan.io/address/0x9BF00b7CFC00D6A7a2e2C994DB8c8dCa467ee359) | USD          |
| [mre7btc](https://etherscan.io/token/0x9fb442d6b612a6dcd2acc67bb53771ef1d9f661a)                  | `MidasOracle`         | [0xB5D648…186D](https://etherscan.io/address/0xB5D6483c496Bc6810b49B983315016Fcb374186D) | BTC          |
| [mre7yield](https://etherscan.io/token/0x87c9053c819bb28e0d73d33059e1b3da80afb0cf)                | `MidasOracle`         | [0x7E8C63…Da93](https://etherscan.io/address/0x7E8C632ab231479886AF1Bc02B9D646e4634Da93) | USD          |
| [mrox](https://etherscan.io/token/0x67e1f506b148d0fc95a4e3ffb49068ceb6849c05)                     | `MidasOracle`         | [0x2c7d47…7c4e](https://etherscan.io/address/0x2c7d47c56015be6aa8442Da78796a965928E7c4e) | USD          |
| [msl](https://etherscan.io/token/0x76cc16608aa7cd32631bb151801bb095313f7bbd)                      | `MidasOracle`         | [0xbdc030…f15c](https://etherscan.io/address/0xbdc0304210972be75Fd2247838BFF2b64474f15c) | USD          |
| [msyrupusd](https://etherscan.io/token/0x20226607b4fa64228abf3072ce561d6257683464)                | `MidasOracle`         | [0x81c097…6f42](https://etherscan.io/address/0x81c097e86842051B1ED4299a9E4d213Cb07f6f42) | USD          |
| [msyrupusdp](https://etherscan.io/token/0x2fe058ccf29f123f9dd2aec0418aa66a877d8e50)               | `MidasOracle`         | [0x783339…Cfb6](https://etherscan.io/address/0x7833397dA276d6B588e76466C14c82b2d733Cfb6) | USD          |
| [mtbill](https://etherscan.io/token/0xdd629e5241cbc5919847783e6c96b2de4754e438)                   | `MidasOracle`         | [0xfCEE97…4A2B](https://etherscan.io/address/0xfCEE9754E8C375e145303b7cE7BEca3201734A2B) | USD          |
| [prime](https://etherscan.io/token/0x19ebb35279a16207ec4ba82799cc64715065f7f6)                    | `FigureOracle`        | [0x19ebb3…f7f6](https://etherscan.io/address/0x19ebb35279a16207ec4ba82799cc64715065f7f6) | USDC         |
| [stockmarkettrbasistrade](https://etherscan.io/token/0x827ce7e8e35861d9ac7fe002749767b695a4994a)  | `MidasOracle`         | [0xCF79a4…1644](https://etherscan.io/address/0xCF79a4ae663117238aB6DD9d0FCca942Be5d1644) | USD          |
| [susn](https://etherscan.io/token/0xe24a3dc889621612422a64e6388927901608b91d)                     | `NoonOracle`          | [0x9f8d0a…0086](https://etherscan.io/address/0x9f8d0a683871125083170f65430f8a15affa0086) | USDC         |
| [tbill](https://etherscan.io/token/0xdd50c053c096cb04a3e3362e2b622529ec5f2e8a)                    | `OpenEdenTBILLOracle` | [0xdd50c0…2e8a](https://etherscan.io/address/0xdd50c053c096cb04a3e3362e2b622529ec5f2e8a) | USDC         |
| [gamiusdc](https://etherscan.io/token/0xdae854d0896ad2fee335689a3f7b4a95fd1a3e46)                 | `ERC4626Oracle`       | [0xdae854…3e46](https://etherscan.io/address/0xdae854d0896ad2fee335689a3f7b4a95fd1a3e46) | USDC         |
| [tulipaUSDC](https://etherscan.io/token/0xce0b790ae0d8cf91e01f3fb69025e14569b574f3)               | `ERC4626Oracle`       | [0xce0b79…74f3](https://etherscan.io/address/0xce0b790ae0d8cf91e01f3fb69025e14569b574f3) | USDC         |
| [9SUSDC](https://etherscan.io/token/0x03d1ec0d01b659b89a87eabb56e4af5cb6e14bfc)                   | `ERC4626Oracle`       | [0x03d1ec…4bfc](https://etherscan.io/address/0x03d1ec0d01b659b89a87eabb56e4af5cb6e14bfc) | USDC         |
| [MtPool-USD](https://etherscan.io/token/0x28663161f9fa2963eb6102b88a741e195e974df6)               | `ERC4626Oracle`       | [0x286631…4df6](https://etherscan.io/address/0x28663161f9fa2963eb6102b88a741e195e974df6) | USDC         |
| [9SicUSDC](https://etherscan.io/token/0x6a39fe461278376f61acbbb6759490e24a78a7b2)                 | `ERC4626Oracle`       | [0x6a39fe…a7b2](https://etherscan.io/address/0x6a39fe461278376f61acbbb6759490e24a78a7b2) | USDC         |
| [flUSD](https://etherscan.io/token/0xd2386d8413c2ec4a761901da14c74a98ebe5054b)                    | `ERC4626Oracle`       | [0xd2386d…054b](https://etherscan.io/address/0xd2386d8413c2ec4a761901da14c74a98ebe5054b) | USDC         |
| [USDst](https://etherscan.io/token/0xcda323c2df692d989b24ba51d0acca924cf9a344)                    | `ERC4626Oracle`       | [0xcda323…a344](https://etherscan.io/address/0xcda323c2df692d989b24ba51d0acca924cf9a344) | USDC         |
| [USDtest](https://etherscan.io/token/0x78295b34d940c780c8c02a607fedf58242e7df2c)                  | `ERC4626Oracle`       | [0x78295b…df2c](https://etherscan.io/address/0x78295b34d940c780c8c02a607fedf58242e7df2c) | USDC         |

Source parameters, token decimals, native prices, payment-token addresses and final payment-token prices are in [the pinned fixture](../test/adapters/ll-adapter/fixtures/oracle-mainnet.json). This is validation data, not a list of deployed oracle addresses.

## Validation

- The 24 Midas feeds, six Centrifuge vaults, six Pareto AA tranches, two Hastra tokens, HYBOND, TBILL, sUSN and eight Lagoon vaults are checked against pinned mainnet state.
- Unit tests cover arithmetic flooring and overflow, source failures, zero quotes, invalid Pareto bindings, price bounds, native decimal normalization and stale Chainlink observations.
- Additional existing oracles retain their unit/fork checks: weETH, wstETH, USD3/sUSD3, sAID loss-adjusted conversion, Asseto NAV and Makina accounting freshness.

Run the oracle tests with an archive `ETH_RPC_URL` and `MAINNET_FORK_BLOCK=26354796`. `OracleCoverageMainnetTest` uses the fixture block independently. No RPC URL or credentials are stored in the fixture.

## Protocol references

- [Centrifuge share pricing](https://docs.centrifuge.io/build/)
- [Lagoon share valuation](https://docs.lagoon.finance/developer-hub/integration/compute-vault-share-valuation) and [fees](https://docs.lagoon.finance/vault/fees)
- [OpenEden TBILL pricing](https://docs.openeden.com/tbill/token-price)
