// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ActivityManifestScript} from "./ActivityManifest.sol";
import {TestnetThreeFFacility, TestnetThreeFRequest} from "../protocols/TestnetThreeF.sol";

import {IThreeFAdapter} from "src/interfaces/IThreeFAdapter.sol";
import {IThreeFVaultController} from "src/interfaces/3f-adapter/IThreeFVaultController.sol";
import {Offer} from "src/interfaces/3f-adapter/ThreeFTypes.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ThreeFActivityScript
/// @notice Finalizes native matured positions and prepares locally funded requests for genuine keystore-signed consumption.
contract ThreeFActivityScript is ActivityManifestScript {
    function run() public {
        (string memory json, string memory market, address owner, uint256 seed) = _manifest();
        address adapter = _address(json, market, "threeFAdapter");
        uint256 settled;
        _start(owner, _broadcast());
        uint256 count = Math.min(IThreeFAdapter(adapter).requestsLength(), 8);
        // Finalization removes by swap-and-pop, so inspect the same index after each successful removal.
        uint256 length = IThreeFAdapter(adapter).requestsLength();
        uint256 index = length > 0 ? vm.envOr("TESTNET_ACTIVITY_CURSOR", uint256(0)) % length : 0;
        for (uint256 i; i < count; ++i) {
            address request = IThreeFAdapter(adapter).requests(index);
            if (IThreeFVaultController(request).canWithdraw()) {
                IThreeFAdapter(adapter).finalizeRequest(request);
                ++settled;
            } else {
                ++index;
            }
            length = IThreeFAdapter(adapter).requestsLength();
            index = length > 0 ? index % length : 0;
        }
        address request;
        uint256 amount;
        if (block.chainid == 31_337 && IThreeFAdapter(adapter).requestsLength() < 8) {
            uint256 marketIndex = vm.envUint("TESTNET_ACTIVITY_MARKET");
            uint256 price = marketIndex == 5 ? 3000 : marketIndex >= 2 && marketIndex <= 4 ? 60_000 : 1;
            amount = vm.parseJsonUint(json, ".seedAssets") * 10
                ** vm.parseJsonUint(json, string.concat(market, ".decimals")) / price / 1000;
            amount = Math.min(amount * (25 + seed % 76) / 100, IThreeFAdapter(adapter).getMaxAssets());
            amount = Math.min(amount, IThreeFAdapter(adapter).maxAssetsPerRequest());
            uint256 cash = IERC20(_address(json, market, "asset")).balanceOf(owner);
            if (amount / 100 > cash) amount = cash * 100;
            if (amount >= IThreeFAdapter(adapter).minAssetsPerRequest() && amount / 100 > 0) {
                request = TestnetThreeFFacility(_address(json, market, "threeFFacility"))
                    .createRequest(uint48(block.timestamp + 7 days));
            }
        }
        _stop(_broadcast());
        _result(
            false,
            settled,
            index,
            block.chainid == 11_155_111
                ? "official auction authorization and real request consumption required"
                : request == address(0) ? "3F capacity or funded budget unavailable" : "signed local request prepared"
        );
        string memory result = vm.readFile(vm.envString("TESTNET_ACTIVITY_RESULT"));
        vm.serializeJson("threef-result", result);
        vm.serializeAddress("threef-result", "request", request);
        result = vm.serializeUint("threef-result", "amount", amount);
        vm.writeJson(result, vm.envString("TESTNET_ACTIVITY_RESULT"));
    }

    function runConsume() public {
        if (block.chainid != 31_337) revert InvalidActivity();
        (string memory json, string memory market, address owner,) = _manifest();
        address request = vm.envAddress("TESTNET_ACTIVITY_REQUEST");
        address adapter = _address(json, market, "threeFAdapter");
        address asset = _address(json, market, "asset");
        if (
            !TestnetThreeFFacility(_address(json, market, "threeFFacility")).isRequest(request)
                || TestnetThreeFRequest(request).asset() != asset || TestnetThreeFRequest(request).owner() != owner
        ) revert InvalidActivity();
        uint256 amount = vm.envUint("TESTNET_ACTIVITY_AMOUNT");
        if (amount == 0 || amount / 100 == 0 || amount / 100 > IERC20(asset).balanceOf(owner)) {
            revert InvalidActivity();
        }
        Offer memory offer = Offer({
            maker: adapter,
            amount: amount,
            expectedReturn: amount / 100,
            nonce: TestnetThreeFRequest(request).nonce(adapter),
            expiration: TestnetThreeFRequest(request).maturity(),
            useCallback: true
        });
        _start(owner, _broadcast());
        IERC20(asset).approve(request, offer.expectedReturn);
        TestnetThreeFRequest(request).fundAndConsume(offer, vm.envBytes("TESTNET_ACTIVITY_SIGNATURE"));
        _stop(_broadcast());
        _result(true, 0, 0, "");
    }
}
