// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IThreeFRequest} from "./IThreeFRequest.sol";

/**
 * @title IThreeFPushRequest
 * @notice Interface for authorized push-mint interface for a 3F request.
 */
interface IThreeFPushRequest is IThreeFRequest {
    /* FUNCTIONS */

    /**
     * @notice Returns the one-time mint authorization for an account.
     * @param account Address that will fund the request and receive its PT and YT.
     * @return principalAssets Authorized principal, denominated in request-asset units.
     * @return yieldAssets Authorized yield, denominated in request-asset units.
     */
    function mintAuthorization(address account) external view returns (uint128 principalAssets, uint128 yieldAssets);

    /**
     * @notice Consumes the caller's authorization, pulls principal, and mints PT/YT to the caller.
     * @dev A request with no authorization can return without minting; callers must validate it first.
     * @param maxPrincipalAssets Maximum principal the caller permits the request to pull.
     * @param minYieldAssets Minimum yield the caller accepts.
     */
    function mint(uint128 maxPrincipalAssets, uint128 minYieldAssets) external;
}
