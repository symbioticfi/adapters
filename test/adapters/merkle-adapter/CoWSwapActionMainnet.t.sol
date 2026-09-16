// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {CoWSwapAction} from "src/contracts/merkle_adapter/CoWSwapAction.sol";
import {ICoWSwapAction} from "src/interfaces/merkle_adapter/ICoWSwapAction.sol";
import {ICoWSwapSettlement} from "src/interfaces/common/ICoWSwapConverter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

/// @dev Types and methods from cowprotocol/contracts GPv2Settlement, GPv2Trade and GPv2Interaction.
interface ICoWActionSettlementMainnet is ICoWSwapSettlement {
    struct Trade {
        uint256 sellTokenIndex;
        uint256 buyTokenIndex;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        uint256 flags;
        uint256 executedAmount;
        bytes signature;
    }

    struct Interaction {
        address target;
        uint256 value;
        bytes callData;
    }

    function authenticator() external view returns (address);
    function preSignature(bytes calldata orderUid) external view returns (uint256);
    function filledAmount(bytes calldata orderUid) external view returns (uint256);
    function settle(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        Trade[] calldata trades,
        Interaction[][3] calldata interactions
    ) external;
}

interface ICoWActionAuthenticationMainnet {
    function manager() external view returns (address);
    function addSolver(address solver) external;
}

/// @dev Real GPv2 and token contracts at a pinned block; solver authorization and DAI funding are fork fixtures.
contract CoWSwapActionMainnetTest is Test {
    uint256 internal constant FORK_BLOCK = 25_982_370;
    address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    IERC20 internal constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 internal constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    ICoWActionSettlementMainnet internal settlement = ICoWActionSettlementMainnet(SETTLEMENT);
    CoWSwapAction internal actionContract;
    ICoWSwapAction.OrderParams internal params;
    address internal adapter = makeAddr("CoW mainnet adapter");
    address internal solver = makeAddr("CoW fork solver");

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("MAINNET_FORK_BLOCK", FORK_BLOCK));
        assertEq(settlement.vaultRelayer(), RELAYER);
        assertEq(settlement.domainSeparator(), 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943);

        MigratablesFactory factory = new MigratablesFactory(address(this));
        factory.whitelist(address(new CoWSwapAction(address(factory), SETTLEMENT)));
        actionContract = CoWSwapAction(factory.create(1, address(this), abi.encode(adapter)));

        ICoWActionAuthenticationMainnet authentication = ICoWActionAuthenticationMainnet(settlement.authenticator());
        vm.prank(authentication.manager());
        authentication.addSolver(solver);

        // Funding fixtures are explicit; settlement uses deployed WETH/DAI and actual GPv2 transfer paths.
        deal(address(WETH), adapter, 2 ether);
        deal(address(DAI), SETTLEMENT, DAI.balanceOf(SETTLEMENT) + 4000 ether);
        vm.prank(adapter);
        WETH.approve(address(actionContract), 2 ether);
        params = ICoWSwapAction.OrderParams({
            buyAmount: 1900 ether,
            validTo: uint32(block.timestamp + 1800),
            appData: keccak256("CoW actionContract fork")
        });
    }

    function test_MainnetOrderExecutesThroughRealSettlementAndPaysTheAdapter() public {
        bytes memory uid = _convert();
        assertEq(settlement.preSignature(uid), uint256(keccak256("GPv2Signing.Scheme.PreSign")));

        _settle(1 ether, adapter);

        assertEq(settlement.filledAmount(uid), 1 ether);
        assertEq(WETH.balanceOf(address(actionContract)), 0);
        assertEq(WETH.allowance(address(actionContract), RELAYER), 0);
        assertEq(DAI.balanceOf(adapter), 2000 ether);
        assertEq(DAI.balanceOf(address(actionContract)), 0);
    }

    function test_MainnetPartialFillCanBeCanceledAndUnusedFundingRecovered() public {
        bytes memory uid = _convert();
        _settle(0.4 ether, adapter);
        assertEq(settlement.filledAmount(uid), 0.4 ether);
        assertEq(WETH.allowance(address(actionContract), RELAYER), 0.6 ether);
        assertEq(DAI.balanceOf(adapter), 800 ether);

        vm.prank(adapter);
        assertEq(actionContract.recover(address(WETH)), 0.6 ether);

        assertEq(settlement.preSignature(uid), 0);
        assertEq(WETH.balanceOf(adapter), 1.6 ether);
        assertEq(WETH.allowance(address(actionContract), RELAYER), 0);
        vm.expectRevert("GPv2: order not presigned");
        _settle(0.6 ether, adapter);
    }

    function test_MainnetCanceledOrderCannotSpendLaterFunding() public {
        bytes memory oldUid = _convert();
        vm.prank(adapter);
        actionContract.invalidateConvert(address(WETH));
        assertEq(settlement.preSignature(oldUid), 0);
        assertEq(WETH.allowance(address(actionContract), RELAYER), 1 ether);
        vm.expectRevert("GPv2: order not presigned");
        _settle(1 ether, adapter);

        ICoWSwapAction.OrderParams memory replacement = params;
        replacement.buyAmount = 1950 ether;
        vm.prank(adapter);
        bytes memory newUid = actionContract.convert(address(WETH), 1 ether, address(DAI), replacement);

        assertEq(settlement.preSignature(oldUid), 0);
        assertGt(settlement.preSignature(newUid), 0);
        vm.expectRevert("GPv2: order not presigned");
        _settle(1 ether, adapter);

        params = replacement;
        _settle(1 ether, adapter);
        assertEq(DAI.balanceOf(adapter), 2000 ether);
    }

    function test_MainnetTamperedReceiverCannotUseThePreSignature() public {
        _convert();
        vm.expectRevert("GPv2: order not presigned");
        _settle(1 ether, solver);

        assertEq(WETH.balanceOf(address(actionContract)), 1 ether);
        assertEq(DAI.balanceOf(solver), 0);
    }

    function _convert() internal returns (bytes memory uid) {
        vm.prank(adapter);
        uid = actionContract.convert(address(WETH), 1 ether, address(DAI), params);
    }

    function _settle(uint256 executedAmount, address receiver) internal {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = WETH;
        tokens[1] = DAI;
        uint256[] memory prices = new uint256[](2);
        prices[0] = 2000;
        prices[1] = 1;
        ICoWActionSettlementMainnet.Trade[] memory trades = new ICoWActionSettlementMainnet.Trade[](1);
        trades[0] = ICoWActionSettlementMainnet.Trade({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: receiver,
            sellAmount: 1 ether,
            buyAmount: params.buyAmount,
            validTo: params.validTo,
            appData: params.appData,
            feeAmount: 0,
            flags: 0x62, // sell, partially fillable, ERC20 balances and pre-signature scheme.
            executedAmount: executedAmount,
            signature: abi.encodePacked(address(actionContract))
        });
        ICoWActionSettlementMainnet.Interaction[][3] memory interactions;
        vm.prank(solver);
        settlement.settle(tokens, prices, trades, interactions);
    }
}
