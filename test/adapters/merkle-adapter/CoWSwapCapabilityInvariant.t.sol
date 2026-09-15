// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {CoWSwapCapability} from "src/contracts/merkle_adapter/CoWSwapCapability.sol";
import {ICoWSwapCapability} from "src/interfaces/merkle_adapter/ICoWSwapCapability.sol";
import {Token} from "test/mocks/Token.sol";
import {CoWCapabilitySettlementMock} from "test/mocks/CoWSwapCapabilityMocks.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @dev Executes arbitrary authorization, partial spending, cancellation and recovery sequences as the adapter.
contract CoWSwapCapabilityHandler is Test {
    CoWSwapCapability public immutable capability;
    CoWCapabilitySettlementMock internal immutable _settlement;
    IERC20 internal immutable _sellToken;
    address internal immutable _buyToken;
    bytes[] public authorizedOrderUids;

    constructor(
        MigratablesFactory factory,
        CoWCapabilitySettlementMock settlement,
        IERC20 sellToken,
        address buyToken
    ) {
        _settlement = settlement;
        _sellToken = sellToken;
        _buyToken = buyToken;
        capability = CoWSwapCapability(factory.create(1, address(this), abi.encode(address(this))));
        sellToken.approve(address(capability), type(uint256).max);
    }

    function authorize(uint256 amount, uint128 minBuy) external {
        uint256 available = _sellToken.balanceOf(address(this)) + _sellToken.balanceOf(address(capability));
        if (available == 0) {
            return;
        }
        amount = bound(amount, 1, available);
        bytes memory uid = capability.convert(
            address(_sellToken),
            amount,
            _buyToken,
            ICoWSwapCapability.OrderParams({
                buyAmount: bound(minBuy, 1, type(uint128).max),
                validTo: uint32(block.timestamp + 1800),
                appData: bytes32(authorizedOrderUids.length)
            })
        );
        authorizedOrderUids.push(uid);
    }

    function consume(uint256 amount) external {
        bytes memory uid = capability.activeOrderUid(address(_sellToken));
        uint256 allowance = _sellToken.allowance(address(capability), _settlement.vaultRelayer());
        if (uid.length == 0 || allowance == 0) {
            return;
        }
        amount = bound(amount, 1, allowance);
        _settlement.consumePresignedSellTokens(uid, address(_sellToken), amount);
    }

    function cancel() external {
        capability.invalidateConvert(address(_sellToken));
    }

    function recover() external {
        capability.recover(address(_sellToken));
    }

    function authorizedOrdersLength() external view returns (uint256) {
        return authorizedOrderUids.length;
    }
}

contract CoWSwapCapabilityInvariantTest is StdInvariant, Test {
    CoWCapabilitySettlementMock internal settlement;
    Token internal tokenIn;
    CoWSwapCapabilityHandler internal handler;
    CoWSwapCapability internal capability;

    function setUp() public {
        vm.warp(1000);
        settlement = new CoWCapabilitySettlementMock();
        tokenIn = new Token("Invariant sell token");
        Token tokenOut = new Token("Invariant buy token");
        MigratablesFactory factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new CoWSwapCapability(address(factory), address(settlement))));
        handler = new CoWSwapCapabilityHandler(factory, settlement, IERC20(address(tokenIn)), address(tokenOut));
        capability = handler.capability();
        tokenIn.transfer(address(handler), 1000);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = CoWSwapCapabilityHandler.authorize.selector;
        selectors[1] = CoWSwapCapabilityHandler.consume.selector;
        selectors[2] = CoWSwapCapabilityHandler.cancel.selector;
        selectors[3] = CoWSwapCapabilityHandler.recover.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_FundingIsConservedAcrossOrdersAndRecovery() public view {
        assertEq(
            tokenIn.balanceOf(address(handler)) + tokenIn.balanceOf(address(capability))
                + tokenIn.balanceOf(address(settlement)),
            1000
        );
    }

    function invariant_RelayerAuthorityNeverExceedsFundedBalance() public view {
        uint256 allowance = tokenIn.allowance(address(capability), settlement.vaultRelayer());
        assertLe(allowance, tokenIn.balanceOf(address(capability)));
        bytes memory activeUid = capability.activeOrderUid(address(tokenIn));
        if (activeUid.length != 0) {
            assertGt(settlement.preSignature(activeUid), 0);
        }
    }

    function invariant_OnlyTheTrackedOrderCanRemainPresigned() public view {
        bytes memory activeUid = capability.activeOrderUid(address(tokenIn));
        uint256 count = handler.authorizedOrdersLength();
        for (uint256 i; i < count; ++i) {
            bytes memory uid = handler.authorizedOrderUids(i);
            if (keccak256(uid) != keccak256(activeUid)) {
                assertEq(settlement.preSignature(uid), 0);
            }
        }
    }
}
