// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ILiquidLaneReactor
 * @notice Interface for consumer request schema and nonce controls of the Liquid Lane Reactor.
 */
interface ILiquidLaneReactor {
    /* STRUCTS */

    /**
     * @notice Minimum output that the Reactor must deliver to complete a request.
     * @param token Output token, or the zero address for native currency.
     * @param amount Minimum output amount.
     * @param recipient Address that receives the output.
     */
    struct Output {
        address token;
        uint256 amount;
        address recipient;
    }

    /**
     * @notice Exact-input request signed by a Liquid Lane consumer.
     * @param tokenIn ERC-20 token sold by the consumer.
     * @param amountIn Exact amount pulled from the consumer by the Reactor.
     * @param outputs Minimum output obligations enforced by the Reactor.
     * @param deadline Last timestamp at which the Reactor may fill the request.
     * @param nonce Consumer-owned nonce consumed on fill or cancellation.
     * @param protocol Signer that authorizes the winning filler and final outputs.
     */
    struct Request {
        address tokenIn;
        uint256 amountIn;
        Output[] outputs;
        uint256 deadline;
        uint256 nonce;
        address protocol;
    }

    /* FUNCTIONS */

    /**
     * @notice Returns whether a consumer nonce has been filled or cancelled.
     * @param swapper Consumer whose nonce is checked.
     * @param nonce Nonce to check.
     * @return used Whether the nonce can no longer be filled.
     */
    function isUsedNonce(address swapper, uint256 nonce) external view returns (bool used);

    /**
     * @notice Permanently invalidates one nonce owned by the caller.
     * @param nonce Nonce to invalidate.
     */
    function invalidateNonce(uint256 nonce) external;
}
