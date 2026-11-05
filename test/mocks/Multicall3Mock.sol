// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";

contract Multicall3Mock {
    function aggregate3(IMulticall3.Call3[] calldata calls)
        external
        payable
        returns (IMulticall3.Result[] memory results)
    {
        results = new IMulticall3.Result[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (results[i].success, results[i].returnData) = calls[i].target.call(calls[i].callData);
            require(calls[i].allowFailure || results[i].success, "Multicall3: call failed");
        }
    }
}
