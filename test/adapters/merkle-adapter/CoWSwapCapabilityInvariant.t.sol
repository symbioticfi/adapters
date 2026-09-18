// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {Test} from "forge-std/Test.sol";
import {CoWSwapCapability} from "src/contracts/merkle_adapter/CoWSwapCapability.sol";
import {ICoWSwapCapability} from "src/interfaces/merkle_adapter/ICoWSwapCapability.sol";
import {Token} from "test/mocks/Token.sol";
import {CoWCapabilitySettlementMock} from "test/mocks/CoWSwapCapabilityMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CoWSwapCapabilityHandler is CapabilityTestBase {
    CoWSwapCapability public implementation;
    CoWCapabilitySettlementMock public settlement;
    Token public sellToken;
    Token public buyToken;
    bytes[] public authorizedOrderUids;
    uint256 public remainingOrder;

    constructor() {
        sellToken = new Token("Sell");
        buyToken = new Token("Buy");
        settlement = new CoWCapabilitySettlementMock();
        _deployAdapter(address(sellToken));
        implementation = new CoWSwapCapability(address(settlement));
        _installCapability(adapter, address(implementation), _cowSelectors());
        sellToken.transfer(address(adapter), 1000);
    }

    function authorize(uint256 amount, uint128 minBuy) external {
        uint256 available = sellToken.balanceOf(address(adapter));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        _manage(address(sellToken), abi.encodeCall(IERC20.approve, (settlement.vaultRelayer(), amount)));
        bytes memory uid = abi.decode(
            _manage(
                address(adapter),
                abi.encodeCall(
                    ICoWSwapCapability.convert,
                    (
                        address(sellToken),
                        amount,
                        address(buyToken),
                        ICoWSwapCapability.OrderParams(
                            bound(minBuy, 1, type(uint128).max),
                            uint32(block.timestamp + 1800),
                            bytes32(authorizedOrderUids.length)
                        )
                    )
                )
            ),
            (bytes)
        );
        authorizedOrderUids.push(uid);
        remainingOrder = amount;
    }

    function consume(uint256 amount) external {
        if (remainingOrder == 0) return;
        amount = bound(amount, 1, remainingOrder);
        settlement.consumePresignedSellTokens(
            CoWSwapCapability(address(adapter)).activeOrderUid(address(sellToken)), address(sellToken), amount
        );
        remainingOrder -= amount;
    }

    function cancel() external {
        _manage(address(adapter), abi.encodeCall(ICoWSwapCapability.invalidateConvert, (address(sellToken))));
        remainingOrder = 0;
    }

    function assertState() external view {
        assertEq(sellToken.balanceOf(address(adapter)) + sellToken.balanceOf(address(settlement)), 1000);
        assertEq(sellToken.balanceOf(address(implementation)), 0);
        bytes memory active = CoWSwapCapability(address(adapter)).activeOrderUid(address(sellToken));
        for (uint256 i; i < authorizedOrderUids.length; ++i) {
            if (keccak256(authorizedOrderUids[i]) != keccak256(active)) {
                assertEq(settlement.preSignature(authorizedOrderUids[i]), 0);
            }
        }
    }
}

contract CoWSwapCapabilityInvariantTest is Test {
    CoWSwapCapabilityHandler internal handler;

    function setUp() public {
        handler = new CoWSwapCapabilityHandler();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.authorize.selector;
        selectors[1] = handler.consume.selector;
        selectors[2] = handler.cancel.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_FundsStayOnAdapterUntilSettlementAndOldOrdersStayRevoked() public view {
        handler.assertState();
    }
}
