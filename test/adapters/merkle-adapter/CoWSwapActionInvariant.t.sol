// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {CoWSwapAction} from "src/contracts/merkle_adapter/CoWSwapAction.sol";
import {ICoWSwapAction} from "src/interfaces/merkle_adapter/ICoWSwapAction.sol";
import {Token} from "test/mocks/Token.sol";
import {CoWActionSettlementMock} from "test/mocks/CoWSwapActionMocks.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @dev Executes arbitrary authorization, partial spending, cancellation and recovery sequences as the adapter.
contract CoWSwapActionHandler is Test {
    CoWSwapAction public immutable actionContract;
    CoWActionSettlementMock internal immutable _settlement;
    IERC20 internal immutable _sellToken;
    address internal immutable _buyToken;
    bytes[] public authorizedOrderUids;

    constructor(MigratablesFactory factory, CoWActionSettlementMock settlement, IERC20 sellToken, address buyToken) {
        _settlement = settlement;
        _sellToken = sellToken;
        _buyToken = buyToken;
        actionContract = CoWSwapAction(factory.create(1, address(this), abi.encode(address(this))));
        sellToken.approve(address(actionContract), type(uint256).max);
    }

    function authorize(uint256 amount, uint128 minBuy) external {
        uint256 available = _sellToken.balanceOf(address(this)) + _sellToken.balanceOf(address(actionContract));
        if (available == 0) {
            return;
        }
        amount = bound(amount, 1, available);
        bytes memory uid = actionContract.convert(
            address(_sellToken),
            amount,
            _buyToken,
            ICoWSwapAction.OrderParams({
                buyAmount: bound(minBuy, 1, type(uint128).max),
                validTo: uint32(block.timestamp + 1800),
                appData: bytes32(authorizedOrderUids.length)
            })
        );
        authorizedOrderUids.push(uid);
    }

    function consume(uint256 amount) external {
        bytes memory uid = actionContract.activeOrderUid(address(_sellToken));
        uint256 allowance = _sellToken.allowance(address(actionContract), _settlement.vaultRelayer());
        if (uid.length == 0 || allowance == 0) {
            return;
        }
        amount = bound(amount, 1, allowance);
        _settlement.consumePresignedSellTokens(uid, address(_sellToken), amount);
    }

    function cancel() external {
        actionContract.invalidateConvert(address(_sellToken));
    }

    function recover() external {
        actionContract.recover(address(_sellToken));
    }

    function authorizedOrdersLength() external view returns (uint256) {
        return authorizedOrderUids.length;
    }
}

contract CoWSwapActionInvariantTest is StdInvariant, Test {
    CoWActionSettlementMock internal settlement;
    Token internal tokenIn;
    CoWSwapActionHandler internal handler;
    CoWSwapAction internal actionContract;

    function setUp() public {
        vm.warp(1000);
        settlement = new CoWActionSettlementMock();
        tokenIn = new Token("Invariant sell token");
        Token tokenOut = new Token("Invariant buy token");
        MigratablesFactory factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new CoWSwapAction(address(factory), address(settlement))));
        handler = new CoWSwapActionHandler(factory, settlement, IERC20(address(tokenIn)), address(tokenOut));
        actionContract = handler.actionContract();
        tokenIn.transfer(address(handler), 1000);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = CoWSwapActionHandler.authorize.selector;
        selectors[1] = CoWSwapActionHandler.consume.selector;
        selectors[2] = CoWSwapActionHandler.cancel.selector;
        selectors[3] = CoWSwapActionHandler.recover.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_FundingIsConservedAcrossOrdersAndRecovery() public view {
        assertEq(
            tokenIn.balanceOf(address(handler)) + tokenIn.balanceOf(address(actionContract))
                + tokenIn.balanceOf(address(settlement)),
            1000
        );
    }

    function invariant_RelayerAuthorityNeverExceedsFundedBalance() public view {
        uint256 allowance = tokenIn.allowance(address(actionContract), settlement.vaultRelayer());
        assertLe(allowance, tokenIn.balanceOf(address(actionContract)));
        bytes memory activeUid = actionContract.activeOrderUid(address(tokenIn));
        if (activeUid.length != 0) {
            assertGt(settlement.preSignature(activeUid), 0);
        }
    }

    function invariant_OnlyTheTrackedOrderCanRemainPresigned() public view {
        bytes memory activeUid = actionContract.activeOrderUid(address(tokenIn));
        uint256 count = handler.authorizedOrdersLength();
        for (uint256 i; i < count; ++i) {
            bytes memory uid = handler.authorizedOrderUids(i);
            if (keccak256(uid) != keccak256(activeUid)) {
                assertEq(settlement.preSignature(uid), 0);
            }
        }
    }
}
