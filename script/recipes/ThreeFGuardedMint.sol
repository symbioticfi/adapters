// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IGuardedCallsCapability} from "src/interfaces/merkle-adapter/capabilities/IGuardedCallsCapability.sol";
import {IThreeFPolicy} from "src/interfaces/merkle-adapter/automations/IThreeFPolicy.sol";
import {IThreeFPushRequest} from "src/interfaces/3f-adapter/IThreeFPushRequest.sol";
import {IThreeFRequestFactory} from "src/interfaces/3f-adapter/IThreeFRequestFactory.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ThreeFGuardedMint
 * @notice Library building the guarded leaf that charges ThreeFPolicy in the same sequence as the mint.
 * @dev The mask and the recipe's binding offsets are both derived here so they cannot drift apart.
 * The leaf pins the policy, asset, request, factory and every check; only the four amount words vary.
 * Those words are bound to the observed principal, yield and cash movements, so an understated
 * charge reverts the whole sequence. Offsets are located by searching for sentinel values rather
 * than computed by hand, because they sit inside a nested ABI encoding.
 */
library ThreeFGuardedMint {
    /* ERRORS */

    /// @notice Raised when a sentinel amount is absent from the encoded payload.
    error SentinelNotFound();

    /* CONSTANTS */

    /// @dev Byte offsets of consume's two amount words within its own calldata: selector plus asset.
    uint256 internal constant ASSETS_ARGUMENT = 36;
    uint256 internal constant YIELD_ARGUMENT = 68;

    uint256 private constant _ASSETS = uint256(keccak256("ThreeFGuardedMint.assets"));
    uint256 private constant _YIELD = uint256(keccak256("ThreeFGuardedMint.yieldAssets"));
    uint128 private constant _PRINCIPAL = uint128(uint256(keccak256("ThreeFGuardedMint.principal")));
    uint128 private constant _MINT_YIELD = uint128(uint256(keccak256("ThreeFGuardedMint.mintYield")));

    /* STRUCTS */

    /**
     * @notice Addresses the leaf pins; none of them can vary at execution time.
     * @param account Custody address holding the PT/YT and the funding cash.
     * @param asset Funding underlying, also the policy's budget key.
     * @param policy ThreeFPolicy charged by the sequence; the account must be an approved consumer.
     * @param request Native 3F request that is minted and queried for share balances.
     * @param requestsFactory Factory whose membership is checked before any call runs.
     */
    struct Config {
        address account;
        address asset;
        address policy;
        address request;
        address requestsFactory;
    }

    /**
     * @notice Encoded guarded call with its mask and the byte offsets of its four variable words.
     * @dev The offsets are strictly ascending, as RecipeExecutor bindings require.
     */
    struct Leaf {
        bytes data;
        bytes dataMask;
        uint256 consumeAssets;
        uint256 consumeYield;
        uint256 mintPrincipal;
        uint256 mintYield;
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Builds the guarded `execute` payload, its mask and its variable-word offsets.
    function build(Config memory config) internal pure returns (Leaf memory leaf) {
        IGuardedCallsCapability.Call[] memory calls = new IGuardedCallsCapability.Call[](2);
        calls[0] = IGuardedCallsCapability.Call({
            target: config.policy, data: abi.encodeCall(IThreeFPolicy.consume, (config.asset, _ASSETS, _YIELD))
        });
        calls[1] = IGuardedCallsCapability.Call({
            target: config.request, data: abi.encodeCall(IThreeFPushRequest.mint, (_PRINCIPAL, _MINT_YIELD))
        });

        IGuardedCallsCapability.Check[] memory checks = new IGuardedCallsCapability.Check[](4);
        checks[0] = IGuardedCallsCapability.Check({
            query: IGuardedCallsCapability.Call({
                target: config.requestsFactory, data: abi.encodeCall(IThreeFRequestFactory.isRequest, (config.request))
            }),
            offset: 0,
            observation: IGuardedCallsCapability.Observation.Before,
            comparison: IGuardedCallsCapability.Comparison.Equal,
            bound: IGuardedCallsCapability.Bound({source: IGuardedCallsCapability.Source.Constant, value: 1, offset: 0})
        });
        checks[1] = _delta(config.request, config.account, 0, ASSETS_ARGUMENT);
        checks[2] = _delta(config.request, config.account, 32, YIELD_ARGUMENT);
        checks[3] = IGuardedCallsCapability.Check({
            query: IGuardedCallsCapability.Call({
                target: config.asset, data: abi.encodeCall(IERC20.balanceOf, (config.account))
            }),
            offset: 0,
            observation: IGuardedCallsCapability.Observation.Decrease,
            comparison: IGuardedCallsCapability.Comparison.Equal,
            bound: IGuardedCallsCapability.Bound({
                source: IGuardedCallsCapability.Source.Calldata, value: 0, offset: ASSETS_ARGUMENT
            })
        });

        leaf.data = abi.encodeCall(IGuardedCallsCapability.execute, (calls, checks));
        leaf.consumeAssets = _find(leaf.data, bytes32(_ASSETS));
        leaf.consumeYield = _find(leaf.data, bytes32(_YIELD));
        leaf.mintPrincipal = _find(leaf.data, bytes32(uint256(_PRINCIPAL)));
        leaf.mintYield = _find(leaf.data, bytes32(uint256(_MINT_YIELD)));
        leaf.dataMask = new bytes(leaf.data.length);
        _mask(leaf.dataMask, leaf.consumeAssets);
        _mask(leaf.dataMask, leaf.consumeYield);
        _mask(leaf.dataMask, leaf.mintPrincipal);
        _mask(leaf.dataMask, leaf.mintYield);
    }

    /// @notice Writes one complete word into an encoded payload, for callers submitting the action directly.
    function write(bytes memory data, uint256 offset, uint256 value) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), value)
        }
    }

    /* PRIVATE FUNCTIONS */

    /// @dev Requires a share balance to rise by exactly the amount declared to the policy.
    function _delta(address request, address account, uint256 offset, uint256 argument)
        private
        pure
        returns (IGuardedCallsCapability.Check memory)
    {
        return IGuardedCallsCapability.Check({
            query: IGuardedCallsCapability.Call({
                target: request, data: abi.encodeCall(IThreeFVaultController.balancesOf, (account))
            }),
            offset: offset,
            observation: IGuardedCallsCapability.Observation.Increase,
            comparison: IGuardedCallsCapability.Comparison.Equal,
            bound: IGuardedCallsCapability.Bound({
                source: IGuardedCallsCapability.Source.Calldata, value: 0, offset: argument
            })
        });
    }

    /// @dev Locates a sentinel word; masked bytes are zeroed by the leaf hash, so its value never binds.
    function _find(bytes memory data, bytes32 sentinel) private pure returns (uint256) {
        uint256 length = data.length;
        for (uint256 i; i + 32 <= length; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), i))
            }
            if (word == sentinel) return i;
        }
        revert SentinelNotFound();
    }

    function _mask(bytes memory dataMask, uint256 offset) private pure {
        for (uint256 i = offset; i < offset + 32; ++i) {
            dataMask[i] = 0xff;
        }
    }
}
