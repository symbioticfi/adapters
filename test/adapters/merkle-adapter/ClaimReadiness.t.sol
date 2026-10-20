// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClaimReadiness} from "src/contracts/merkle-adapter/automations/ClaimReadiness.sol";
import {IClaimReadiness} from "src/interfaces/merkle-adapter/automations/IClaimReadiness.sol";
import {IThreeFFacility} from "src/interfaces/3f-adapter/IThreeFAdapterDependencies.sol";

import {Test} from "forge-std/Test.sol";

contract ClaimReadinessTest is Test {
    address internal constant SOURCE = address(0x100);
    address internal constant ACCOUNT = address(0x200);
    address internal constant STRATEGY = address(0x300);
    ClaimReadiness internal _selector;

    function setUp() public {
        _selector = new ClaimReadiness();
        vm.warp(1000);
    }

    function test_NoonSelectsMaturedZeroIdAndRefreshesAfterClaim() public {
        _mock("getUserNextRequestId(address)", abi.encode(ACCOUNT), abi.encode(3));
        _mock("withdrawPeriod()", "", abi.encode(100));
        _noon(0, 7, 900, false);
        _noon(1, 9, 901, false);
        _noon(2, 11, 800, false);
        (uint256 id, uint256 ready) = _selector.nextNoon(SOURCE, ACCOUNT);
        vm.snapshotGasLastCall("ClaimReadiness", "NextNoon");
        assertEq(id, 0);
        assertEq(ready, 7);
        assertEq(_selector.noonReady(SOURCE, ACCOUNT, 0), 7);
        _noon(0, 7, 900, true);
        assertEq(_selector.noonReady(SOURCE, ACCOUNT, 0), 0);
        (id, ready) = _selector.nextNoon(SOURCE, ACCOUNT);
        assertEq(id, 2);
        assertEq(ready, 11);
        _noon(2, 11, 800, true);
        (, ready) = _selector.nextNoon(SOURCE, ACCOUNT);
        assertEq(ready, 0);
    }

    function test_NoonFutureAndOverflowingCooldownAreNotReady() public {
        _mock("getUserNextRequestId(address)", abi.encode(ACCOUNT), abi.encode(2));
        _mock("withdrawPeriod()", "", abi.encode(type(uint256).max));
        _noon(0, 7, 0, false);
        _noon(1, 9, type(uint256).max, false);
        (, uint256 ready) = _selector.nextNoon(SOURCE, ACCOUNT);
        assertEq(ready, 0);
    }

    function test_NoonEmptyLedgerDoesNotReadAnInvalidId() public {
        _mock("getUserNextRequestId(address)", abi.encode(ACCOUNT), abi.encode(0));
        assertEq(_selector.noonReady(SOURCE, ACCOUNT, 0), 0);
    }

    function test_NoonFailsInsteadOfTruncatingOwnerLedger() public {
        _mock("getUserNextRequestId(address)", abi.encode(ACCOUNT), abi.encode(4097));
        vm.expectRevert(IClaimReadiness.ScanLimit.selector);
        _selector.nextNoon(SOURCE, ACCOUNT);
    }

    function test_ParetoDepositWaitsForPrefundingAndReturnsWholeOwnerAmount() public {
        _pareto();
        _deposit(0, 17, 2e18, 0, 1);
        _deposit(1, 23, 2e18, 0, 0);
        _deposit(2, 31, 0, 0, 0);
        (uint256 epoch, uint256 ready) = _selector.nextPareto(SOURCE, ACCOUNT, true);
        assertEq(epoch, 1);
        assertEq(ready, 23);
        _deposit(1, 0, 2e18, 0, 0);
        _deposit(0, 17, 2e18, 0, 0);
        (epoch, ready) = _selector.nextPareto(SOURCE, ACCOUNT, true);
        assertEq(epoch, 0);
        assertEq(ready, 17);
    }

    function test_ParetoWithdrawalWaitsForSettlementAndSkipsEmptyEpochs() public {
        _pareto();
        _withdrawal(0, 0, 0, 0);
        _withdrawal(1, 23, 2e18, 1);
        _withdrawal(2, 31, 2e18, 0);
        (uint256 epoch, uint256 ready) = _selector.nextPareto(SOURCE, ACCOUNT, false);
        assertEq(epoch, 2);
        assertEq(ready, 31);
        assertEq(_selector.paretoEpochReady(SOURCE, ACCOUNT, false, 2), 31);
        _withdrawal(2, 0, 2e18, 0);
        assertEq(_selector.paretoEpochReady(SOURCE, ACCOUNT, false, 2), 0);
        _withdrawal(1, 23, 2e18, 0);
        (epoch, ready) = _selector.nextPareto(SOURCE, ACCOUNT, false);
        assertEq(epoch, 1);
        assertEq(ready, 23);
    }

    function test_ParetoFailsInsteadOfTruncatingEpochScope() public {
        _pareto();
        vm.mockCall(STRATEGY, abi.encodeWithSignature("epochNumber()"), abi.encode(4095));
        vm.expectRevert(IClaimReadiness.ScanLimit.selector);
        _selector.nextPareto(SOURCE, ACCOUNT, false);
    }

    function test_RequiredOwnerLedgerFailureBubbles() public {
        _mock("getUserNextRequestId(address)", abi.encode(ACCOUNT), abi.encode(1));
        _mock("withdrawPeriod()", "", abi.encode(100));
        vm.mockCallRevert(
            SOURCE, abi.encodeWithSignature("getWithdrawalRequest(address,uint256)", ACCOUNT, 0), "failed"
        );
        vm.expectRevert(bytes("failed"));
        _selector.nextNoon(SOURCE, ACCOUNT);
    }

    function test_ParetoDirectNormalWaitsForEpochAndCompleteCash() public {
        _direct();
        (bool ok,) = address(_selector)
            .staticcall(abi.encodeWithSignature("paretoReady(address,address,bool)", SOURCE, ACCOUNT, false));
        assertTrue(ok);
        assertEq(_ready(false), 0);
        vm.mockCall(STRATEGY, abi.encodeWithSignature("epochNumber()"), abi.encode(3));
        // 10 normal + 20 open APR0 + 30 settled + 4 interest + 2 newly settled interest.
        assertEq(_ready(false), 66);
        vm.mockCall(address(0x400), abi.encodeWithSignature("balanceOf(address)", STRATEGY), abi.encode(65));
        assertEq(_ready(false), 0);
    }

    function test_ParetoInstantRequiresEnabledAndCash() public {
        _direct();
        assertEq(_ready(true), 55);
        _mock("allowInstantWithdraw()", "", abi.encode(false));
        assertEq(_ready(true), 0);
    }

    function test_ThreeFSelectsWholeLiveAuthorizationAndRespectsPolicyBudget() public {
        address request = _threeF();
        (bool ok, bytes memory result) = address(_selector)
            .staticcall(
                abi.encodeWithSignature(
                    "nextThreeF(address,address,address,address,uint32,uint32,uint256)",
                    SOURCE,
                    ACCOUNT,
                    address(0x400),
                    address(0x500),
                    uint32(0),
                    uint32(512),
                    100
                )
            );
        assertTrue(ok);
        (address selected, uint256 principal, uint256 yieldAssets) = abi.decode(result, (address, uint256, uint256));
        assertEq(selected, request);
        assertEq(principal, 50);
        assertEq(yieldAssets, 5);
        _mock("remainingAssets(address,address)", abi.encode(address(0x400), address(0x500)), abi.encode(49));
        (, result) = address(_selector)
            .staticcall(
                abi.encodeWithSignature(
                    "nextThreeF(address,address,address,address,uint32,uint32,uint256)",
                    SOURCE,
                    ACCOUNT,
                    address(0x400),
                    address(0x500),
                    uint32(0),
                    uint32(512),
                    100
                )
            );
        (selected, principal,) = abi.decode(result, (address, uint256, uint256));
        assertEq(selected, address(0));
        assertEq(principal, 0);
    }

    function test_ThreeFScanCannotOmitExistingRequest() public {
        address request = _threeF();
        vm.mockCall(STRATEGY, abi.encodeWithSignature("isRequest(address)", request), abi.encode(true));
        (bool ok,) = address(_selector)
            .staticcall(
                abi.encodeWithSignature(
                    "nextThreeF(address,address,address,address,uint32,uint32,uint256)",
                    SOURCE,
                    ACCOUNT,
                    address(0x400),
                    address(0x500),
                    uint32(0),
                    uint32(0),
                    100
                )
            );
        assertFalse(ok);
    }

    function test_ThreeFSkipsAuthorizationForDifferentCollateral() public {
        address first = _threeF();
        address second = vm.computeCreateAddress(STRATEGY, 10);
        _threeFIntent(first, 0, address(0x600), address(0x700), address(0x999));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("isRequest(address)", second), abi.encode(true));
        vm.mockCall(second, abi.encodeWithSignature("asset()"), abi.encode(address(0x400)));
        vm.mockCall(
            second, abi.encodeWithSignature("mintAuthorization(address)", ACCOUNT), abi.encode(uint128(60), uint128(6))
        );
        _threeFIntent(second, 1, address(0x601), address(0x701), address(0x500));
        (address selected, uint256 principal, uint256 yieldAssets) =
            _selector.nextThreeF(SOURCE, ACCOUNT, address(0x400), address(0x500), 0, 512, 100);
        assertEq(selected, second);
        assertEq(principal, 60);
        assertEq(yieldAssets, 6);
        vm.snapshotGasLastCall("ClaimReadiness", "NextThreeF");
    }

    function test_ThreeFWithdrawalSelectsFullConvertedAssetsOnlyWhenReady() public {
        _mock("canWithdraw()", "", abi.encode(false));
        assertEq(_threeFReady(), 0);
        _mock("canWithdraw()", "", abi.encode(true));
        _mock("balancesOf(address)", abi.encode(ACCOUNT), abi.encode(0, 0));
        assertEq(_threeFReady(), 0);
        _mock("balancesOf(address)", abi.encode(ACCOUNT), abi.encode(10, 20));
        _mock("convertToAssets(uint256,uint256)", abi.encode(10, 20), abi.encode(7, 2));
        uint256 amount = _threeFReady();
        vm.snapshotGasLastCall("ClaimReadiness", "ThreeFReady");
        assertEq(amount, 9);
        _mock("balancesOf(address)", abi.encode(ACCOUNT), abi.encode(0, 0));
        assertEq(_threeFReady(), 0);
    }

    function test_ThreeFWithdrawalDoesNotInventValueForWorthlessShares() public {
        _mock("canWithdraw()", "", abi.encode(true));
        _mock("balancesOf(address)", abi.encode(ACCOUNT), abi.encode(0, 20));
        _mock("convertToAssets(uint256,uint256)", abi.encode(0, 20), abi.encode(0, 0));
        assertEq(_threeFReady(), 0);
    }

    function _threeFReady() internal view returns (uint256) {
        (bool ok, bytes memory result) =
            address(_selector).staticcall(abi.encodeWithSignature("threeFReady(address,address)", SOURCE, ACCOUNT));
        require(ok, "threeFReady query failed");
        return abi.decode(result, (uint256));
    }

    function _threeF() internal returns (address request) {
        request = vm.computeCreateAddress(STRATEGY, 7);
        _mock("REQUESTS_FACTORY()", "", abi.encode(STRATEGY));
        _mock("account()", "", abi.encode(ACCOUNT));
        _mock("FACILITY()", "", abi.encode(address(0x800)));
        _mock("minYieldPerRequest(address)", abi.encode(address(0x500)), abi.encode(0.1e8));
        _mock("remainingAssets(address,address)", abi.encode(address(0x400), address(0x500)), abi.encode(100));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("isRequest(address)"), abi.encode(false));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("isRequest(address)", request), abi.encode(true));
        vm.mockCall(request, abi.encodeWithSignature("asset()"), abi.encode(address(0x400)));
        vm.mockCall(
            request, abi.encodeWithSignature("mintAuthorization(address)", ACCOUNT), abi.encode(uint128(50), uint128(5))
        );
        _threeFIntent(request, 0, address(0x600), address(0x700), address(0x500));
    }

    function _threeFIntent(address request, uint256 id, address manager, address collateral, address underlying)
        internal
    {
        IThreeFFacility.IntentProperties memory properties;
        properties.targetAsset = IThreeFFacility.Asset(manager, true);
        vm.mockCall(request, abi.encodeWithSignature("name()"), abi.encode(string.concat("request-", vm.toString(id))));
        vm.mockCall(
            address(0x800),
            abi.encodeWithSignature("getIntent(uint256)", id),
            abi.encode(properties, address(0), request, true)
        );
        vm.mockCall(manager, abi.encodeWithSignature("assets()"), abi.encode(collateral, address(0)));
        vm.mockCall(collateral, abi.encodeWithSignature("underlying()"), abi.encode(underlying));
    }

    function _ready(bool instant) internal view returns (uint256) {
        (bool ok, bytes memory result) = address(_selector)
            .staticcall(abi.encodeWithSignature("paretoReady(address,address,bool)", SOURCE, ACCOUNT, instant));
        require(ok);
        return abi.decode(result, (uint256));
    }

    function _direct() internal {
        _mock("strategy()", "", abi.encode(STRATEGY));
        _mock("allowInstantWithdraw()", "", abi.encode(true));
        _mock("epochEndDate()", "", abi.encode(1000));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("token()"), abi.encode(address(0x400)));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("epochNumber()"), abi.encode(2));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("lastWithdrawRequest(address)", ACCOUNT), abi.encode(2));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("withdrawsRequests(address)", ACCOUNT), abi.encode(10));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("instantWithdrawsRequests(address)", ACCOUNT), abi.encode(55));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("apr0Users(address)", ACCOUNT), abi.encode(20, 2, 30, 4));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("apr0RateByEpoch(uint256)", 2), abi.encode(0.1e18));
        vm.mockCall(address(0x400), abi.encodeWithSignature("balanceOf(address)", STRATEGY), abi.encode(100));
    }

    function _pareto() internal {
        _mock("strategy()", "", abi.encode(STRATEGY));
        vm.mockCall(STRATEGY, abi.encodeWithSignature("epochNumber()"), abi.encode(1));
    }

    function _noon(uint256 id, uint256 amount, uint256 timestamp, bool claimed) internal {
        _mock("getWithdrawalRequest(address,uint256)", abi.encode(ACCOUNT, id), abi.encode(amount, timestamp, claimed));
    }

    function _deposit(uint256 epoch, uint256 amount, uint256 price, uint256 pending, uint256 prefunded) internal {
        _mock("userDepositsEpochs(address,uint256)", abi.encode(ACCOUNT, epoch), abi.encode(amount));
        _mock("epochPrice(uint256)", abi.encode(epoch), abi.encode(price));
        _mock("epochPendingDeposits(uint256)", abi.encode(epoch), abi.encode(pending));
        _mock("epochPrefundedDeposits(uint256)", abi.encode(epoch), abi.encode(prefunded));
    }

    function _withdrawal(uint256 epoch, uint256 amount, uint256 price, uint256 pending) internal {
        _mock("userWithdrawalsEpochs(address,uint256)", abi.encode(ACCOUNT, epoch), abi.encode(amount));
        _mock("epochWithdrawPrice(uint256)", abi.encode(epoch), abi.encode(price));
        _mock("epochPendingClaims(uint256)", abi.encode(epoch), abi.encode(pending));
    }

    function _mock(string memory signature, bytes memory args, bytes memory result) internal {
        vm.mockCall(SOURCE, bytes.concat(bytes4(keccak256(bytes(signature))), args), result);
    }
}
