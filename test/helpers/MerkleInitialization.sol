// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";
import {ICREOracle} from "src/interfaces/merkle-adapter/oracle/ICREOracle.sol";

function defaultOracleInitParams(address admin) pure returns (ICREOracle.InitParams memory) {
    return ICREOracle.InitParams({
        defaultAdminRoleHolder: admin,
        oracleGuardRoleHolder: address(0),
        oracleLimitsRoleHolder: address(0),
        maxOracleGrowth: 100_000,
        maxOracleLoss: 100_000
    });
}

function merkleAdapterInitParams(address admin) pure returns (IMerkleAdapter.InitParams memory) {
    return IMerkleAdapter.InitParams({
        oracleData: abi.encode(defaultOracleInitParams(admin)),
        merkleAccountData: abi.encode(IMerkleAccount.InitParams({defaultAdminRoleHolder: admin}))
    });
}
