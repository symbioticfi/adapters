// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AaveV3Liquidity} from "../../../src/contracts/merkle-adapter/automations/liquidity/AaveV3Liquidity.sol";
import {MerkleFundingLens} from "../../../src/contracts/merkle-adapter/automations/liquidity/MerkleFundingLens.sol";
import {IMerkleFundingLens} from "../../../src/interfaces/merkle-adapter/automations/liquidity/IMerkleFundingLens.sol";

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract FundingSourceMock {
    uint256 public capacity;
    address public account;

    constructor(address newAccount, uint256 newCapacity) {
        account = newAccount;
        capacity = newCapacity;
    }

    function available(address owner) public view returns (uint256) {
        require(owner == account);
        return capacity;
    }

    function values(address owner) public view returns (uint256, uint256) {
        require(owner == account);
        return (7, capacity);
    }
}

contract MerkleFundingLensTest is Test {
    address internal _lens;
    address internal _asset;
    address internal _account = address(0x1234);

    function setUp() public {
        _lens = address(new MerkleFundingLens());
        _asset = address(new ERC20Mock());
        ERC20Mock(_asset).mint(_account, 100e6);
    }

    /// forge-config: default.isolate = true
    function test_AccountCashWithoutSources() public {
        uint256 assets =
            IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, new IMerkleFundingLens.Source[](0));
        vm.snapshotGasLastCall("MerkleFundingLens", "cashOnly");
        assertEq(assets, 100e6);
    }

    /// forge-config: default.isolate = true
    function test_CashAndDisjointSynchronousSources() public {
        IMerkleFundingLens.Source[] memory sources = _sources();
        uint256 assets = IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources);
        vm.snapshotGasLastCall("MerkleFundingLens", "twoSources");
        assertEq(assets, 600e6);
    }

    function test_UsesAaveHelperLiquidityAndModeChecks() public {
        address helper = address(new AaveV3Liquidity());
        address pool = makeAddr("pool");
        address aToken = address(new ERC20Mock());
        ERC20Mock(aToken).mint(_account, 500e6);
        ERC20Mock(_asset).mint(aToken, 200e6);
        vm.mockCall(pool, abi.encodeWithSignature("getUserEMode(address)", _account), abi.encode(uint256(0)));
        vm.mockCall(pool, abi.encodeWithSignature("getConfiguration(address)", _asset), abi.encode(uint256(1) << 56));
        vm.mockCall(pool, abi.encodeWithSignature("getReserveAToken(address)", _asset), abi.encode(aToken));
        vm.mockCall(
            pool, abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", _asset), abi.encode(uint128(300e6))
        );
        vm.mockCall(pool, abi.encodeWithSignature("getUserConfiguration(address)", _account), abi.encode(uint256(0)));
        IMerkleFundingLens.Source[] memory sources = new IMerkleFundingLens.Source[](1);
        sources[0] = IMerkleFundingLens.Source({
            id: keccak256(abi.encode(pool, _asset)),
            target: helper,
            data: abi.encodeCall(AaveV3Liquidity.liquidityWithBorrow, (pool, _asset, _account)),
            offset: 0
        });
        assertEq(IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources), 300e6);
        vm.mockCall(pool, abi.encodeWithSignature("getUserEMode(address)", _account), abi.encode(uint256(1)));
        assertEq(IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources), 100e6);
    }

    function test_InvalidOffsetAndSourceCountRejected() public {
        IMerkleFundingLens.Source[] memory sources = _sources();
        sources[0].offset = 1;
        vm.expectRevert(IMerkleFundingLens.InvalidSource.selector);
        IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources);
        vm.expectRevert(IMerkleFundingLens.InvalidSource.selector);
        IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, new IMerkleFundingLens.Source[](33));
    }

    function testFuzz_AmountsRemainInFundingAssetUnits(uint96 cash, uint96 first, uint96 second) public {
        ERC20Mock(_asset).burn(_account, 100e6);
        ERC20Mock(_asset).mint(_account, cash);
        IMerkleFundingLens.Source[] memory sources = _sources();
        sources[0].target = address(new FundingSourceMock(_account, first));
        sources[1].target = address(new FundingSourceMock(_account, second));
        assertEq(
            IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources), uint256(cash) + first + second
        );
    }

    function test_DuplicatePositionRejectedEvenWithDifferentQueries() public {
        IMerkleFundingLens.Source[] memory sources = _sources();
        sources[1].id = sources[0].id;
        vm.expectRevert(IMerkleFundingLens.DuplicateSource.selector);
        IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources);
    }

    function test_DuplicateQueryRejectedEvenWithDifferentIds() public {
        IMerkleFundingLens.Source[] memory sources = _sources();
        sources[1].target = sources[0].target;
        sources[1].data = sources[0].data;
        sources[1].offset = 0;
        vm.expectRevert(IMerkleFundingLens.DuplicateSource.selector);
        IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources);
    }

    function test_ConfiguredReadFailureDoesNotReturnCashOnly() public {
        IMerkleFundingLens.Source[] memory sources = _sources();
        sources[0].data = abi.encodeCall(FundingSourceMock.available, (address(0x5678)));
        vm.expectRevert(IMerkleFundingLens.SourceReadFailed.selector);
        IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources);
    }

    function test_ShortReplyRejected() public {
        IMerkleFundingLens.Source[] memory sources = _sources();
        vm.mockCall(sources[1].target, sources[1].data, abi.encode(uint256(9)));
        vm.expectRevert(IMerkleFundingLens.SourceReadFailed.selector);
        IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources);
    }

    function test_InvalidSourceRejected() public {
        IMerkleFundingLens.Source[] memory sources = _sources();
        sources[0].id = bytes32(0);
        vm.expectRevert(IMerkleFundingLens.InvalidSource.selector);
        IMerkleFundingLens(_lens).getAvailableAssets(_account, _asset, sources);
    }

    function test_InvalidAccountRejected() public {
        vm.expectRevert(IMerkleFundingLens.InvalidSource.selector);
        IMerkleFundingLens(_lens).getAvailableAssets(address(0), _asset, new IMerkleFundingLens.Source[](0));
    }

    function _sources() internal returns (IMerkleFundingLens.Source[] memory sources) {
        sources = new IMerkleFundingLens.Source[](2);
        sources[0] = IMerkleFundingLens.Source({
            id: bytes32(uint256(1)),
            target: address(new FundingSourceMock(_account, 200e6)),
            data: abi.encodeCall(FundingSourceMock.available, (_account)),
            offset: 0
        });
        sources[1] = IMerkleFundingLens.Source({
            id: bytes32(uint256(2)),
            target: address(new FundingSourceMock(_account, 300e6)),
            data: abi.encodeCall(FundingSourceMock.values, (_account)),
            offset: 32
        });
    }
}
