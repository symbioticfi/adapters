// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IMidnight} from "morpho-midnight/src/interfaces/IMidnight.sol";

import {IMorpho} from "morpho-blue/src/interfaces/IMorpho.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {UpstreamArtifacts} from "./UpstreamArtifacts.sol";
import {UpstreamAave} from "./UpstreamAave.sol";

import {IIrm} from "morpho-blue/src/interfaces/IIrm.sol";
import {MarketParams, Market as BlueMarket} from "morpho-blue/src/interfaces/IMorpho.sol";

import {CALLBACK_SUCCESS} from "morpho-midnight/src/libraries/ConstantsLib.sol";
import {IRatifier} from "morpho-midnight/src/interfaces/IRatifier.sol";
import {Market, CollateralParams, Offer} from "morpho-midnight/src/interfaces/IMidnight.sol";

/// @title TestnetCollateralOracle
/// @notice Explicit collateral-to-loan price in the native Morpho 1e36 scale.
contract TestnetCollateralOracle is Ownable {
    error InvalidPrice();
    uint256 public price;
    event SetPrice(uint256 price);

    constructor(address newOwner, uint256 newPrice) Ownable(newOwner) {
        price = newPrice;
    }

    function setPrice(uint256 newPrice) public onlyOwner {
        if (newPrice == 0) revert InvalidPrice();
        price = newPrice;
        emit SetPrice(newPrice);
    }
}

/// @title TestnetFixedIRM
/// @notice Deterministic per-second Morpho borrow rate used for reproducible accrual.
contract TestnetFixedIRM is IIrm {
    function borrowRate(MarketParams memory, BlueMarket memory) public pure returns (uint256) {
        return uint256(8e16) / 365 days;
    }

    function borrowRateView(MarketParams memory, BlueMarket memory) public pure returns (uint256) {
        return uint256(8e16) / 365 days;
    }
}

/// @title TestnetMidnightLender
/// @notice Funded contract lender that ratifies only an exact owner-approved native offer and taker.
contract TestnetMidnightLender is Ownable, IRatifier {
    using SafeERC20 for IERC20;
    error InvalidOffer();
    address public immutable midnight;
    bytes32 public approvedOffer;
    address public taker;
    event ApproveOffer(bytes32 indexed hash, address indexed taker);
    event Withdraw(bytes32 indexed marketHash, address indexed receiver, uint256 units);
    event WithdrawCash(address indexed token, address indexed receiver, uint256 amount);

    constructor(address newOwner, address newMidnight) Ownable(newOwner) {
        midnight = newMidnight;
        IMidnight(newMidnight).setIsAuthorized(address(this), true, address(this));
    }

    function approveOffer(Offer memory offer, address newTaker) public onlyOwner {
        if (
            offer.maker != address(this) || offer.ratifier != address(this) || offer.market.midnight != midnight
                || !offer.buy
        ) revert InvalidOffer();
        approvedOffer = keccak256(abi.encode(offer));
        taker = newTaker;
        IERC20(offer.market.loanToken).forceApprove(midnight, offer.maxAssets);
        emit ApproveOffer(approvedOffer, newTaker);
    }

    function isRatified(Offer memory offer, bytes memory, address newTaker) public view returns (bytes32) {
        if (midnight != msg.sender || newTaker != taker || keccak256(abi.encode(offer)) != approvedOffer) {
            revert InvalidOffer();
        }
        return CALLBACK_SUCCESS;
    }

    /// @notice Withdraws repaid native market credit to the owner's chosen receiver.
    function withdraw(Market memory market, uint256 units, address receiver) public onlyOwner {
        if (market.midnight != midnight) revert InvalidOffer();
        IMidnight(midnight).withdraw(market, units, address(this), receiver);
        emit Withdraw(keccak256(abi.encode(market)), receiver, units);
    }

    /// @notice Withdraws lender-held cash; outstanding credit remains a position at the native engine.
    function withdrawCash(address token, uint256 amount, address receiver) public onlyOwner {
        IERC20(token).safeTransfer(receiver, amount);
        emit WithdrawCash(token, receiver, amount);
    }
}

/// @title TestnetNativeLendingScript
/// @notice Deploys source-pinned native Morpho engines and bounded fixture dependencies.
contract TestnetNativeLendingScript is UpstreamArtifacts {
    struct Deployment {
        address blue;
        address midnight;
        address midnightLender;
        address oracle;
        address irm;
        address aaveV4;
        bytes blueParams;
        bytes midnightParams;
        bytes32 blueId;
        bytes32 midnightId;
    }
    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;

    constructor(address newOwner, bool newBroadcast) {
        _OWNER = newOwner;
        _BROADCAST = newBroadcast;
    }

    function deploy(address asset, address collateral, uint256 collateralPrice)
        public
        returns (Deployment memory deployed)
    {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
        deployed.blue = _deployArtifact("morpho-blue", "Morpho", abi.encode(_OWNER));
        deployed.oracle = address(new TestnetCollateralOracle(_OWNER, collateralPrice));
        deployed.irm = address(new TestnetFixedIRM());

        {
            MarketParams memory blueParams = MarketParams({
                loanToken: asset, collateralToken: collateral, oracle: deployed.oracle, irm: deployed.irm, lltv: 75e16
            });
            IMorpho(deployed.blue).enableIrm(deployed.irm);
            IMorpho(deployed.blue).enableLltv(blueParams.lltv);
            IMorpho(deployed.blue).createMarket(blueParams);
            // Encode the static tuple directly to avoid Solidity 0.8.37's IR stack limit when encoding this struct
            // inside the larger dynamic Deployment return. The result is identical to abi.encode(blueParams).
            deployed.blueParams = abi.encode(asset, collateral, deployed.oracle, deployed.irm, blueParams.lltv);
            deployed.blueId = keccak256(deployed.blueParams);
        }
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
        address helper = address(new UpstreamAave(_OWNER, _BROADCAST));
        UpstreamAave.Deployment memory aave = UpstreamAave(helper).deploy();
        UpstreamAave(helper).addReserve(asset, 1e18);
        deployed.aaveV4 = aave.spoke;
        return deployMidnight(deployed, asset, collateral);
    }

    function deployMidnight(Deployment memory deployed, address asset, address collateral)
        public
        returns (Deployment memory)
    {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
        if (deployed.midnight == address(0)) deployed.midnight = _deployArtifact("morpho-midnight", "Midnight", "");
        deployed.midnightLender = address(new TestnetMidnightLender(_OWNER, deployed.midnight));
        {
            CollateralParams[] memory collaterals = new CollateralParams[](1);
            collaterals[0] =
                CollateralParams({token: collateral, lltv: 75e16, liquidationCursor: 5e17, oracle: deployed.oracle});
            Market memory midnightParams = Market({
                chainId: block.chainid,
                midnight: deployed.midnight,
                loanToken: asset,
                collateralParams: collaterals,
                maturity: block.timestamp + 30 days,
                rcfThreshold: 0,
                enterGate: address(0),
                liquidatorGate: address(0)
            });
            IMidnight(deployed.midnight).enableLltv(75e16);
            IMidnight(deployed.midnight).enableLiquidationCursor(5e17);
            deployed.midnightId = IMidnight(deployed.midnight).touchMarket(midnightParams);
            deployed.midnightParams = abi.encode(midnightParams);
        }
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
        return deployed;
    }
}
