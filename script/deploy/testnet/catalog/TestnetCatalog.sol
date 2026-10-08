// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TestnetCatalog
 * @notice Library for the complete local integration catalog and source-pinned fixture parameters.
 * @dev Numeric mechanisms: 0 Midas comp, 1 Midas noncomp, 2 Midas cutoff, 3 ERC7540,
 * 4 issuer provider, 5 native yield queue, 6 ETH queue, 7 ERC4626.
 */
library TestnetCatalog {
    error UnknownProfile();

    struct Profile {
        string symbol;
        uint8 market;
        uint8 mechanism;
        uint8 variant;
        uint48 cooldown;
        uint256 minPrice;
        uint256 maxPrice;
        uint256 fixturePrice;
    }

    function count() internal pure returns (uint256) {
        return 53;
    }

    function profile(uint256 index) internal pure returns (Profile memory) {
        if (index == 0) {
            return Profile({
                symbol: "AA_FalconX",
                market: 0,
                mechanism: 5,
                variant: 10,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 1) {
            return Profile({
                symbol: "ACRDX",
                market: 0,
                mechanism: 3,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 3_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 2) {
            return Profile({
                symbol: "ACRED",
                market: 0,
                mechanism: 4,
                variant: 0,
                cooldown: 0,
                minPrice: 10_000_000_000_000_000_000,
                maxPrice: 1_000_000_000_000_000_000_000,
                fixturePrice: 100_000_000_000_000_000_000
            });
        }
        if (index == 3) {
            return Profile({
                symbol: "AUTO",
                market: 0,
                mechanism: 5,
                variant: 1,
                cooldown: 1 days,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 4) {
            return Profile({
                symbol: "CarryTradeUSDTRYLeverage",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 12 hours,
                minPrice: 261_000_000_000_000_000,
                maxPrice: 3_653_400_000_000_000_000,
                fixturePrice: 1_044_000_000_000_000_000
            });
        }
        if (index == 5) {
            return Profile({
                symbol: "DUSD",
                market: 0,
                mechanism: 5,
                variant: 2,
                cooldown: 72 minutes,
                minPrice: 515_533_500_000_000_000,
                maxPrice: 2_062_134_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 6) {
            return Profile({
                symbol: "HYB",
                market: 0,
                mechanism: 3,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 3_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 7) {
            return Profile({
                symbol: "JAAA",
                market: 0,
                mechanism: 3,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 3_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 8) {
            return Profile({
                symbol: "JTRSY",
                market: 0,
                mechanism: 3,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 3_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 9) {
            return Profile({
                symbol: "PRIME",
                market: 0,
                mechanism: 5,
                variant: 0,
                cooldown: 18 hours,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 10) {
            return Profile({
                symbol: "SPKCC",
                market: 0,
                mechanism: 4,
                variant: 5,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_000_000_000_000_000_000,
                fixturePrice: 1_030_000_000_000_000_000
            });
        }
        if (index == 11) {
            return Profile({
                symbol: "STAC",
                market: 0,
                mechanism: 4,
                variant: 1,
                cooldown: 0,
                minPrice: 100_000_000_000_000_000_000,
                maxPrice: 10_000_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000_000
            });
        }
        if (index == 12) {
            return Profile({
                symbol: "StockMarketTRBasisTrade",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 12 hours,
                minPrice: 253_000_000_000_000_000,
                maxPrice: 3_541_400_000_000_000_000,
                fixturePrice: 1_012_000_000_000_000_000
            });
        }
        if (index == 13) {
            return Profile({
                symbol: "USCC",
                market: 0,
                mechanism: 4,
                variant: 3,
                cooldown: 12 hours,
                minPrice: 1_140_000_000_000_000_000,
                maxPrice: 114_000_000_000_000_000_000,
                fixturePrice: 11_400_000_000_000_000_000
            });
        }
        if (index == 14) {
            return Profile({
                symbol: "USD3",
                market: 0,
                mechanism: 5,
                variant: 4,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 15) {
            return Profile({
                symbol: "VBILL",
                market: 0,
                mechanism: 4,
                variant: 2,
                cooldown: 0,
                minPrice: 950_000_000_000_000_000,
                maxPrice: 1_050_000_000_000_000_000,
                fixturePrice: 1_020_000_000_000_000_000
            });
        }
        if (index == 16) {
            return Profile({
                symbol: "bEQTY",
                market: 0,
                mechanism: 4,
                variant: 4,
                cooldown: 0,
                minPrice: 10_000_000_000_000_000_000,
                maxPrice: 1_000_000_000_000_000_000_000,
                fixturePrice: 100_000_000_000_000_000_000
            });
        }
        if (index == 17) {
            return Profile({
                symbol: "deCRDX",
                market: 0,
                mechanism: 3,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 3_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 18) {
            return Profile({
                symbol: "deJAAA",
                market: 0,
                mechanism: 3,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 3_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 19) {
            return Profile({
                symbol: "deJTRSY",
                market: 0,
                mechanism: 3,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 3_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 20) {
            return Profile({
                symbol: "liUSD13w",
                market: 0,
                mechanism: 5,
                variant: 9,
                cooldown: 7 days,
                minPrice: 610_302_338_122_868_364,
                maxPrice: 2_441_209_352_491_473_456,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 21) {
            return Profile({
                symbol: "liUSD4w",
                market: 0,
                mechanism: 5,
                variant: 8,
                cooldown: 3 days,
                minPrice: 599_319_571_104_044_928,
                maxPrice: 2_397_278_284_416_179_714,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 22) {
            return Profile({
                symbol: "mAPOLLO",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 275_000_000_000_000_000,
                maxPrice: 3_850_500_000_000_000_000,
                fixturePrice: 1_100_000_000_000_000_000
            });
        }
        if (index == 23) {
            return Profile({
                symbol: "mBASIS",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 298_900_000_000_000_000,
                maxPrice: 4_184_700_000_000_000_000,
                fixturePrice: 1_195_600_000_000_000_000
            });
        }
        if (index == 24) {
            return Profile({
                symbol: "mBTC",
                market: 2,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 516_201_565_000_000_000,
                maxPrice: 2_064_806_260_000_000_000,
                fixturePrice: 1_032_403_130_000_000_000
            });
        }
        if (index == 25) {
            return Profile({
                symbol: "mEDGE",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 280_800_000_000_000_000,
                maxPrice: 3_931_300_000_000_000_000,
                fixturePrice: 1_123_200_000_000_000_000
            });
        }
        if (index == 26) {
            return Profile({
                symbol: "mEVUSD",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 522_689_035_000_000_000,
                maxPrice: 2_090_756_140_000_000_000,
                fixturePrice: 1_045_378_070_000_000_000
            });
        }
        if (index == 27) {
            return Profile({
                symbol: "mFARM",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 506_302_310_000_000_000,
                maxPrice: 2_025_209_240_000_000_000,
                fixturePrice: 1_012_604_620_000_000_000
            });
        }
        if (index == 28) {
            return Profile({
                symbol: "mFONE",
                market: 0,
                mechanism: 1,
                variant: 0,
                cooldown: 36 hours,
                minPrice: 275_900_000_000_000_000,
                maxPrice: 3_862_200_000_000_000_000,
                fixturePrice: 1_103_600_000_000_000_000
            });
        }
        if (index == 29) {
            return Profile({
                symbol: "mGLOBAL",
                market: 0,
                mechanism: 2,
                variant: 0,
                cooldown: 12 hours,
                minPrice: 251_441_200_000_000_000,
                maxPrice: 3_520_176_800_000_000_000,
                fixturePrice: 1_005_764_800_000_000_000
            });
        }
        if (index == 30) {
            return Profile({
                symbol: "mHYPER",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 6 hours,
                minPrice: 277_200_000_000_000_000,
                maxPrice: 3_880_300_000_000_000_000,
                fixturePrice: 1_108_800_000_000_000_000
            });
        }
        if (index == 31) {
            return Profile({
                symbol: "mHyperBTC",
                market: 4,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 510_936_340_000_000_000,
                maxPrice: 2_043_745_360_000_000_000,
                fixturePrice: 1_021_872_680_000_000_000
            });
        }
        if (index == 32) {
            return Profile({
                symbol: "mHyperETH",
                market: 5,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 512_254_525_000_000_000,
                maxPrice: 2_049_018_100_000_000_000,
                fixturePrice: 1_024_509_050_000_000_000
            });
        }
        if (index == 33) {
            return Profile({
                symbol: "mM1USD",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 253_500_000_000_000_000,
                maxPrice: 3_548_800_000_000_000_000,
                fixturePrice: 1_014_000_000_000_000_000
            });
        }
        if (index == 34) {
            return Profile({
                symbol: "mMEV",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 282_900_000_000_000_000,
                maxPrice: 3_961_200_000_000_000_000,
                fixturePrice: 1_131_600_000_000_000_000
            });
        }
        if (index == 35) {
            return Profile({
                symbol: "mROX",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 6 hours,
                minPrice: 282_900_000_000_000_000,
                maxPrice: 3_961_200_000_000_000_000,
                fixturePrice: 1_131_600_000_000_000_000
            });
        }
        if (index == 36) {
            return Profile({
                symbol: "mRe7BTC",
                market: 3,
                mechanism: 0,
                variant: 0,
                cooldown: 2 days,
                minPrice: 495_671_835_000_000_000,
                maxPrice: 1_982_687_340_000_000_000,
                fixturePrice: 991_343_670_000_000_000
            });
        }
        if (index == 37) {
            return Profile({
                symbol: "mRe7YIELD",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 3 days,
                minPrice: 266_900_000_000_000_000,
                maxPrice: 3_736_600_000_000_000_000,
                fixturePrice: 1_067_600_000_000_000_000
            });
        }
        if (index == 38) {
            return Profile({
                symbol: "mSL",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 577_306_345_000_000_000,
                maxPrice: 2_309_225_380_000_000_000,
                fixturePrice: 1_154_612_690_000_000_000
            });
        }
        if (index == 39) {
            return Profile({
                symbol: "mTBILL",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 266_300_000_000_000_000,
                maxPrice: 3_727_800_000_000_000_000,
                fixturePrice: 1_065_200_000_000_000_000
            });
        }
        if (index == 40) {
            return Profile({
                symbol: "mevBTC",
                market: 3,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 511_811_155_000_000_000,
                maxPrice: 2_047_244_620_000_000_000,
                fixturePrice: 1_023_622_310_000_000_000
            });
        }
        if (index == 41) {
            return Profile({
                symbol: "msyrupUSD",
                market: 0,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 509_226_070_000_000_000,
                maxPrice: 2_036_904_280_000_000_000,
                fixturePrice: 1_018_452_140_000_000_000
            });
        }
        if (index == 42) {
            return Profile({
                symbol: "msyrupUSDp",
                market: 6,
                mechanism: 0,
                variant: 0,
                cooldown: 1 days,
                minPrice: 264_400_000_000_000_000,
                maxPrice: 3_701_100_000_000_000_000,
                fixturePrice: 1_057_600_000_000_000_000
            });
        }
        if (index == 43) {
            return Profile({
                symbol: "sAID",
                market: 0,
                mechanism: 5,
                variant: 3,
                cooldown: 6 days,
                minPrice: 527_574_236_280_171_822,
                maxPrice: 2_110_296_945_120_687_290,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 44) {
            return Profile({
                symbol: "sUSD3",
                market: 0,
                mechanism: 5,
                variant: 5,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 45) {
            return Profile({
                symbol: "sUSN",
                market: 0,
                mechanism: 5,
                variant: 7,
                cooldown: 17 hours,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 46) {
            return Profile({
                symbol: "sthUSD",
                market: 0,
                mechanism: 5,
                variant: 6,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 47) {
            return Profile({
                symbol: "weETH",
                market: 5,
                mechanism: 6,
                variant: 1,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 48) {
            return Profile({
                symbol: "wstETH",
                market: 5,
                mechanism: 6,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 2_500_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 49) {
            return Profile({
                symbol: "ERC4626",
                market: 1,
                mechanism: 7,
                variant: 0,
                cooldown: 0,
                minPrice: 500_000_000_000_000_000,
                maxPrice: 3_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        if (index == 50) {
            return Profile({
                symbol: "ASSETO",
                market: 0,
                mechanism: 4,
                variant: 6,
                cooldown: 12 hours,
                minPrice: 1_000_000_000_000_000_000,
                maxPrice: 100_000_000_000_000_000_000,
                fixturePrice: 11_200_000_000_000_000_000
            });
        }
        if (index == 51) {
            return Profile({
                symbol: "OPENEDEN",
                market: 0,
                mechanism: 4,
                variant: 7,
                cooldown: 12 hours,
                minPrice: 1,
                maxPrice: 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935,
                fixturePrice: 1_080_000_000_000_000_000
            });
        }
        if (index == 52) {
            return Profile({
                symbol: "SECURITIZE_DAILY",
                market: 0,
                mechanism: 4,
                variant: 8,
                cooldown: 0,
                minPrice: 100_000_000_000_000_000,
                maxPrice: 10_000_000_000_000_000_000,
                fixturePrice: 1_000_000_000_000_000_000
            });
        }
        revert UnknownProfile();
    }
}
