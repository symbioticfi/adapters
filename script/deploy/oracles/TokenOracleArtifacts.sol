// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Compile every fixed oracle for vm.getCode without embedding their creation bytecode.
import {
    AA_AdaptiveFrontier_Oracle
} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/AA_AdaptiveFrontier_Oracle.sol";
import {AA_Bastion_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/AA_Bastion_Oracle.sol";
import {AA_FalconX_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/AA_FalconX_Oracle.sol";
import {
    AA_Fasanara_Oracle
} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/AA_Fasanara_Oracle.sol";
import {
    AA_RockawayX_Oracle
} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/AA_RockawayX_Oracle.sol";
import {ACRDX_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/ACRDX_Oracle.sol";
import {AUTO_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/AUTO_Oracle.sol";
import {
    CarryTradeUSDTRYLeverage_Oracle
} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/CarryTradeUSDTRYLeverage_Oracle.sol";
import {deJAAA_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/deJAAA_Oracle.sol";
import {deJTRSY_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/deJTRSY_Oracle.sol";
import {HYB_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/HYB_Oracle.sol";
import {HYBOND_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/HYBOND_Oracle.sol";
import {JAAA_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/JAAA_Oracle.sol";
import {JTRSY_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/JTRSY_Oracle.sol";
import {mAPOLLO_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mAPOLLO_Oracle.sol";
import {mBASIS_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mBASIS_Oracle.sol";
import {mBTC_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mBTC_Oracle.sol";
import {mEDGE_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mEDGE_Oracle.sol";
import {mFONE_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mFONE_Oracle.sol";
import {mGLO_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mGLO_Oracle.sol";
import {mGLOBAL_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mGLOBAL_Oracle.sol";
import {mHYPER_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mHYPER_Oracle.sol";
import {mHyperBTC_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mHyperBTC_Oracle.sol";
import {mM1USD_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mM1USD_Oracle.sol";
import {mRe7BTC_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mRe7BTC_Oracle.sol";
import {mRe7YIELD_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mRe7YIELD_Oracle.sol";
import {mROX_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mROX_Oracle.sol";
import {mSL_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mSL_Oracle.sol";
import {msyrupUSD_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/msyrupUSD_Oracle.sol";
import {msyrupUSDp_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/msyrupUSDp_Oracle.sol";
import {mTBILL_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/mTBILL_Oracle.sol";
import {PRIME_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/PRIME_Oracle.sol";
import {
    StockMarketTRBasisTrade_Oracle
} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/StockMarketTRBasisTrade_Oracle.sol";
import {sUSN_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/sUSN_Oracle.sol";
import {TBILL_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/TBILL_Oracle.sol";
import {gamiUSDC_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/gamiUSDC_Oracle.sol";
import {tulipaUSDC_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/tulipaUSDC_Oracle.sol";
import {
    NineSummitsUSDC_Oracle
} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/NineSummitsUSDC_Oracle.sol";
import {MtPoolUSD_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/MtPoolUSD_Oracle.sol";
import {
    NineSummitsInstitutionalUSDC_Oracle
} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/NineSummitsInstitutionalUSDC_Oracle.sol";
import {flUSD_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/flUSD_Oracle.sol";
import {USDst_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/USDst_Oracle.sol";
import {USDtest_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/USDtest_Oracle.sol";
import {fxLOOP_Oracle} from "../../../src/contracts/merkle-adapter/connectors/oracles/tokens/fxLOOP_Oracle.sol";
