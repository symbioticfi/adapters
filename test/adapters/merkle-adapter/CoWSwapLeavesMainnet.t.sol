// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IMerkleAccount} from "src/interfaces/merkle-adapter/IMerkleAccount.sol";

import {CapabilityTestBase} from "./CapabilityTestBase.sol";
import {MerkleAdapterDelegatorMock, MerkleAdapterVaultMock} from "test/adapters/MerkleAdapter.t.sol";

import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {GPv2Order} from "src/libraries/GPv2Order.sol";
import {ICoWSwapSettlement} from "src/interfaces/common/ICoWSwapConverter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Types and methods from cowprotocol/contracts GPv2Settlement, GPv2Trade and GPv2Interaction.
interface ICoWSettlementMainnet is ICoWSwapSettlement {
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
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        Trade[] calldata trades,
        Interaction[][3] calldata interactions
    ) external;
}

interface ICoWAuthenticationMainnet {
    function manager() external view returns (address);
    function addSolver(address solver) external;
}

/// @dev Real GPv2 and tokens at a pinned block; solver authorization, funding and the vault/oracle are fixtures.
contract CoWSwapLeavesMainnetTest is CapabilityTestBase {
    uint256 internal constant FORK_BLOCK = 25_982_370;
    address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    GPv2Order.Data internal order;
    bytes internal signature;
    address internal solver = makeAddr("CoW fork solver");

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("MAINNET_FORK_BLOCK", FORK_BLOCK));
        assertEq(ICoWSettlementMainnet(SETTLEMENT).vaultRelayer(), RELAYER);
        assertEq(
            ICoWSettlementMainnet(SETTLEMENT).domainSeparator(),
            0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943
        );

        _deployAdapter(WETH);

        address authentication = ICoWSettlementMainnet(SETTLEMENT).authenticator();
        vm.prank(ICoWAuthenticationMainnet(authentication).manager());
        ICoWAuthenticationMainnet(authentication).addSolver(solver);

        // Funding fixtures are explicit; settlement uses deployed WETH/DAI and actual GPv2 transfer paths.
        deal(WETH, account, 2 ether);
        deal(DAI, SETTLEMENT, IERC20(DAI).balanceOf(SETTLEMENT) + 4000 ether);
        _manage(WETH, abi.encodeCall(IERC20.approve, (RELAYER, 1 ether)));
        order = GPv2Order.Data({
            sellToken: IERC20(WETH),
            buyToken: IERC20(DAI),
            receiver: account,
            sellAmount: 1 ether,
            buyAmount: 1900 ether,
            validTo: uint32(block.timestamp + 1800),
            appData: keccak256("CoW EIP-712 leaves fork"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function test_MainnetOrderExecutesThroughRealSettlementAndPaysTheAdapter() public {
        bytes memory uid = _authorize();
        assertEq(ICoWSettlementMainnet(SETTLEMENT).preSignature(uid), 0);
        _settle(1 ether, account);
        assertEq(ICoWSettlementMainnet(SETTLEMENT).filledAmount(uid), 1 ether);
        assertEq(IERC20(WETH).allowance(account, RELAYER), 0);
        assertEq(IERC20(WETH).balanceOf(account), 1 ether);
        assertEq(IERC20(DAI).balanceOf(account), 2000 ether);
    }

    function test_MainnetDelayedSettlementCannotSpendCurrentOrLaterVaultReserves() public {
        address delegator = address(new MerkleAdapterDelegatorMock(adapter.vault()));
        MerkleAdapterVaultMock(adapter.vault()).setDelegator(delegator);
        deal(WETH, adapter.vault(), 1.25 ether);
        MerkleAdapterDelegatorMock(delegator).allocate(address(adapter), 0.5 ether);
        assertEq(adapter.reservedAssets(), 0.5 ether);

        order.sellAmount = 2 ether;
        order.buyAmount = 3800 ether;
        _manage(WETH, abi.encodeCall(IERC20.approve, (RELAYER, type(uint256).max)));
        bytes memory uid = _authorize();

        // A later allocation is not part of the already-authorized order's custody.
        MerkleAdapterDelegatorMock(delegator).allocate(address(adapter), 0.75 ether);
        assertEq(IERC20(WETH).allowance(address(adapter), RELAYER), 0);
        _settle(2 ether, account);
        assertEq(ICoWSettlementMainnet(SETTLEMENT).filledAmount(uid), 2 ether);
        assertEq(IERC20(WETH).balanceOf(account), 0);
        assertEq(IERC20(DAI).balanceOf(account), 4000 ether);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 1.25 ether);
        assertEq(adapter.reservedAssets(), 1.25 ether);

        // A distinct valid order and remaining allowance cannot borrow the adapter's reserves.
        order.appData = keccak256("second CoW order after exhausting account");
        order.sellAmount = 1 ether;
        order.buyAmount = 1900 ether;
        uid = _authorize();
        assertEq(IERC20(WETH).allowance(account, RELAYER), type(uint256).max);
        vm.expectCall(WETH, abi.encodeCall(IERC20.transferFrom, (account, SETTLEMENT, 1 ether)));
        vm.expectRevert(bytes(""));
        _settle(1 ether, account);
        assertEq(ICoWSettlementMainnet(SETTLEMENT).filledAmount(uid), 0);
        assertEq(IERC20(WETH).balanceOf(account), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 1.25 ether);
        assertEq(adapter.reservedAssets(), 1.25 ether);
        assertEq(IERC20(WETH).allowance(address(adapter), RELAYER), 0);
    }

    function test_MainnetRevokedOrderCannotSpendFunding() public {
        _authorize();
        _manage(account, abi.encodeCall(IMerkleAccount.revokeSignature, (_digest())));
        vm.expectRevert("GPv2: invalid eip1271 signature");
        _settle(1 ether, account);
        assertEq(IERC20(WETH).balanceOf(account), 2 ether);
        assertEq(IERC20(WETH).allowance(account, RELAYER), 1 ether);
    }

    function test_MainnetTamperedReceiverCannotUseTheSignature() public {
        _authorize();
        vm.expectRevert("GPv2: invalid eip1271 signature");
        _settle(1 ether, solver);
        assertEq(IERC20(WETH).balanceOf(account), 2 ether);
        assertEq(IERC20(DAI).balanceOf(solver), 0);
    }

    function test_MainnetApprovalOfDifferentOrderCannotAuthorizeSellOrder() public {
        GPv2Order.Data memory wrong = order;
        wrong.kind = GPv2Order.KIND_BUY;
        _manage(
            account,
            abi.encodeCall(
                IMerkleAccount.setSignature,
                (ICoWSettlementMainnet(SETTLEMENT).domainSeparator(), abi.encode(GPv2Order.TYPE_HASH, wrong))
            )
        );
        vm.expectRevert("GPv2: invalid eip1271 signature");
        _settle(1 ether, account);
        assertEq(IERC20(WETH).balanceOf(account), 2 ether);
    }

    function test_MainnetSellOrderCannotBePartiallyFilled() public {
        bytes memory uid = _authorize();
        // For a full-fill sell order, the solver's executedAmount does not reduce the signed amount.
        _settle(0.4 ether, account);
        assertEq(ICoWSettlementMainnet(SETTLEMENT).filledAmount(uid), 1 ether);
        assertEq(IERC20(DAI).balanceOf(account), 2000 ether);
    }

    function test_MainnetExpiredOrderCannotSpendFunding() public {
        _authorize();
        vm.warp(uint256(order.validTo) + 1);
        vm.expectRevert("GPv2: order expired");
        _settle(1 ether, account);
    }

    function _authorize() internal returns (bytes memory uid) {
        bytes32 digest = _digest();
        _manage(
            account,
            abi.encodeCall(
                IMerkleAccount.setSignature,
                (ICoWSettlementMainnet(SETTLEMENT).domainSeparator(), abi.encode(GPv2Order.TYPE_HASH, order))
            )
        );
        assertEq(IMerkleAccount(account).isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
        assertEq(adapter.getCapabilities().length, 0);
        return abi.encodePacked(digest, account, order.validTo);
    }

    function _digest() internal view returns (bytes32) {
        return GPv2Order.hash(order, ICoWSettlementMainnet(SETTLEMENT).domainSeparator());
    }

    function _settle(uint256 executedAmount, address receiver) internal {
        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = DAI;
        uint256[] memory prices = new uint256[](2);
        prices[0] = 2000;
        prices[1] = 1;
        ICoWSettlementMainnet.Trade[] memory trades = new ICoWSettlementMainnet.Trade[](1);
        trades[0] = ICoWSettlementMainnet.Trade({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: receiver,
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: 0,
            flags: 0x40, // full-fill sell, ERC20 balances and EIP-1271 scheme.
            executedAmount: executedAmount,
            signature: abi.encodePacked(account, signature)
        });
        ICoWSettlementMainnet.Interaction[][3] memory interactions;
        vm.prank(solver);
        ICoWSettlementMainnet(SETTLEMENT).settle(tokens, prices, trades, interactions);
    }
}
