// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";
import {ORACLE_LIMIT_PRECISION} from "src/interfaces/merkle-adapter/oracle/ICREOracleBase.sol";

function defaultOracleInitParams(address admin, address forwarder) pure returns (ICREOracle.InitParams memory) {
    return ICREOracle.InitParams({
        forwarder: forwarder,
        defaultAdminRoleHolder: admin,
        oracleGuardRoleHolder: address(0),
        oracleLimitsRoleHolder: address(0),
        maxOracleGrowth: ORACLE_LIMIT_PRECISION / 10,
        maxOracleLoss: ORACLE_LIMIT_PRECISION / 10,
        oracleTolerance: 0
    });
}

function merkleAdapterInitParams(address admin, address forwarder) pure returns (IMerkleAdapter.InitParams memory) {
    return IMerkleAdapter.InitParams({
        oracleData: abi.encode(defaultOracleInitParams(admin, forwarder)),
        merkleAccountData: abi.encode(IMerkleAccount.InitParams({defaultAdminRoleHolder: admin}))
    });
}
