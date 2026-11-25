// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {FigureAccount, FigureSubAccount} from "../../../../src/contracts/ll-adapter/FigureAccount.sol";
import {FigureOracle} from "../../../../src/contracts/ll-adapter/oracles/FigureOracle.sol";
import {ParetoAccount} from "../../../../src/contracts/ll-adapter/ParetoAccount.sol";
import {ParetoOracle} from "../../../../src/contracts/ll-adapter/oracles/ParetoOracle.sol";

import {IParetoCDO} from "../../../../src/interfaces/ll-adapter/pareto/IParetoCDO.sol";
import {IParetoCreditVault} from "../../../../src/interfaces/ll-adapter/pareto/IParetoCreditVault.sol";
import {IParetoWithdrawalQueue} from "../../../../src/interfaces/ll-adapter/pareto/IParetoWithdrawalQueue.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Script} from "forge-std/Script.sol";

/**
 * @title ITestnetYieldVault
 * @notice Interface for funded yield model administration; ERC-4626 provides token/deposit/withdraw APIs.
 */
interface ITestnetYieldVault is IERC4626 {
    /**
     * @notice Raised when an amount is zero, exceeds backing, or is not available in cash.
     */
    error InvalidAmount();
    /**
     * @notice Raised when a request is missing, already processed, or not ready.
     */
    error InvalidRequest();
    /**
     * @notice Raised when the caller cannot operate the request or endpoint.
     */
    error InvalidCaller();
    /**
     * @notice Raised when a timestamp has not reached the required boundary.
     */
    error NotMature();
    /**
     * @notice Emitted when cash is deployed as an explicitly tracked credit receivable.
     */
    event DeployCapital(address indexed receiver, uint256 assets);
    /**
     * @notice Emitted when externally funded capital and yield return to the vault.
     */
    event RepayCapital(address indexed payer, uint256 principal, uint256 yield);
    /**
     * @notice Emitted when an outstanding credit receivable is written down.
     */
    event RecognizeLoss(uint256 assets);
    /**
     * @notice Returns outstanding off-vault principal included in NAV.
     */
    function receivable() external view returns (uint256);
    /**
     * @notice Returns cash reserved for burned-share asynchronous requests.
     */
    function reservedAssets() external view returns (uint256);
    /**
     * @notice Returns the actual asset balance held by the vault.
     */
    function cash() external view returns (uint256);
    /**
     * @notice Deploys actual cash and records a same-value credit receivable.
     */
    function deployCapital(address receiver, uint256 assets) external;
    /**
     * @notice Returns actual approved assets, separating principal repayment from funded yield.
     */
    function repayCapital(uint256 principal, uint256 yield) external;
    /**
     * @notice Writes down outstanding principal, reducing the share NAV.
     */
    function recognizeLoss(uint256 assets) external;
}

/// @title TestnetYieldVault
/// @notice Funded ERC-4626 model with cash-limited exits, explicit credit exposure, and realized losses.
contract TestnetYieldVault is ERC4626, Ownable, ITestnetYieldVault {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /* IMMUTABLES */
    uint8 internal immutable _OFFSET;

    /* STATE VARIABLES */
    uint256 public receivable;
    uint256 public reservedAssets;

    /* CONSTRUCTOR */
    constructor(address newAsset, address newOwner, string memory newName, string memory newSymbol, uint8 newDecimals)
        ERC20(newName, newSymbol)
        ERC4626(IERC20(newAsset))
        Ownable(newOwner)
    {
        _OFFSET = newDecimals - IERC20Metadata(newAsset).decimals();
    }

    /* PUBLIC FUNCTIONS */
    /// @inheritdoc ITestnetYieldVault
    function cash() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @inheritdoc IERC4626
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return (cash() + receivable).saturatingSub(reservedAssets);
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address account) public view virtual override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(super.maxWithdraw(account), cash().saturatingSub(reservedAssets));
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address account) public view virtual override(ERC4626, IERC4626) returns (uint256) {
        uint256 shares = balanceOf(account);
        uint256 available = cash().saturatingSub(reservedAssets);
        return convertToAssets(shares) <= available ? shares : convertToShares(available);
    }

    /// @inheritdoc ITestnetYieldVault
    function deployCapital(address receiver, uint256 assets) public onlyOwner {
        if (receiver == address(0) || assets == 0 || assets > cash().saturatingSub(reservedAssets)) {
            revert InvalidAmount();
        }
        receivable += assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit DeployCapital(receiver, assets);
    }

    /// @inheritdoc ITestnetYieldVault
    function repayCapital(uint256 principal, uint256 yield) public {
        if (principal > receivable || principal + yield == 0) revert InvalidAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), principal + yield);
        receivable -= principal;
        emit RepayCapital(msg.sender, principal, yield);
    }

    /// @inheritdoc ITestnetYieldVault
    function recognizeLoss(uint256 assets) public onlyOwner {
        if (assets == 0 || assets > receivable || assets > totalAssets()) revert InvalidAmount();
        receivable -= assets;
        emit RecognizeLoss(assets);
    }

    /* INTERNAL FUNCTIONS */
    function _decimalsOffset() internal view override returns (uint8) {
        return _OFFSET;
    }

    function _reserve(address account, uint256 shares) internal returns (uint256 assets) {
        if (shares == 0) revert InvalidAmount();
        assets = convertToAssets(shares);
        _burn(account, shares);
        reservedAssets += assets;
    }

    function _payReserve(address receiver, uint256 assets) internal {
        if (assets > cash()) revert InvalidAmount();
        reservedAssets -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
    }
}

/**
 *  @title ITestnetFigureVault @notice Interface for the Figure yield-vault model and admin settlement.
 */
interface ITestnetFigureVault {
    /**
     * @notice Burns shares into the holder's pending redemption slot.
     */
    function requestRedeem(uint256 shares) external;
    /**
     * @notice Returns the pending shares, asset quote and original request timestamp.
     */
    function pendingRedemptions(address account)
        external
        view
        returns (uint256 shares, uint256 assets, uint256 timestamp);
    /**
     * @notice Emitted when shares enter a holder's pending redemption slot.
     */
    event RequestRedeem(address indexed account, uint256 shares, uint256 assets);
    /**
     * @notice Emitted when real reserved cash is paid to a matured holder.
     */
    event Finalize(address indexed account, uint256 assets);
    /**
     * @notice Returns the minimum admin settlement delay.
     */
    function settlementDelay() external view returns (uint48);
    /**
     * @notice Pays a matured request from existing cash, clearing the slot before transfer.
     */
    function finalize(address account) external;
}

/// @title TestnetFigureYieldVault
/// @notice Figure wYLDS model with one burned-share request slot per holder and admin cash settlement.
contract TestnetFigureYieldVault is TestnetYieldVault, ITestnetFigureVault {
    /* STATE VARIABLES */
    struct Pending {
        uint256 shares;
        uint256 assets;
        uint256 timestamp;
    }
    mapping(address account => Pending request) public pendingRedemptions;
    uint48 public immutable settlementDelay = 2 days;

    /* CONSTRUCTOR */
    constructor(address newAsset, address newOwner)
        TestnetYieldVault(
            newAsset, newOwner, "Testnet wrapped yield dollars", "wYLDS", IERC20Metadata(newAsset).decimals()
        )
    {}

    /* PUBLIC FUNCTIONS */
    /// @inheritdoc ITestnetFigureVault
    function requestRedeem(uint256 shares) public {
        if (pendingRedemptions[msg.sender].shares > 0) revert InvalidRequest();
        uint256 assets = _reserve(msg.sender, shares);
        pendingRedemptions[msg.sender] = Pending({shares: shares, assets: assets, timestamp: block.timestamp});
        emit RequestRedeem(msg.sender, shares, assets);
    }

    /// @inheritdoc ITestnetFigureVault
    function finalize(address account) public onlyOwner {
        Pending memory request = pendingRedemptions[account];
        if (request.shares == 0) revert InvalidRequest();
        if (block.timestamp < request.timestamp + settlementDelay) revert NotMature();
        delete pendingRedemptions[account];
        _payReserve(account, request.assets);
        emit Finalize(account, request.assets);
    }

    /// @inheritdoc IERC4626
    function redeem(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert InvalidRequest();
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert InvalidRequest();
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }
}

/**
 *  @title ITestnetParetoTranche @notice Interface for configuring native CDO and queue redemption endpoints.
 */
interface ITestnetParetoTranche {
    /**
     * @notice Returns the authorized native CDO.
     */
    function cdo() external view returns (address);
    /**
     * @notice Returns the authorized native epoch queue.
     */
    function queue() external view returns (address);
    /**
     * @notice Emitted when redemption endpoints are configured.
     */
    event SetEndpoints(address indexed cdo, address indexed queue);

    /**
     * @notice Configures the unique CDO and epoch queue once.
     */
    function setEndpoints(address newCdo, address newQueue) external;
}

/// @title TestnetParetoTranche
/// @notice Funded AA tranche whose underlying can leave only through the native CDO or epoch queue.
contract TestnetParetoTranche is TestnetYieldVault, ITestnetParetoTranche {
    address public cdo;
    address public queue;
    constructor(address newAsset, address newOwner)
        TestnetYieldVault(newAsset, newOwner, "Testnet Pareto FalconX senior tranche", "AA_FalconX", 18)
    {}

    /// @inheritdoc ITestnetParetoTranche
    function setEndpoints(address newCdo, address newQueue) public onlyOwner {
        if (cdo != address(0) || newCdo == address(0) || newQueue == address(0)) revert InvalidRequest();
        cdo = newCdo;
        queue = newQueue;
        emit SetEndpoints(newCdo, newQueue);
    }

    function _withdraw(address caller, address receiver, address account, uint256 assets, uint256 shares)
        internal
        override
    {
        if ((caller != cdo && caller != queue) || caller != receiver || caller != account) {
            revert InvalidCaller();
        }
        super._withdraw(caller, receiver, account, assets, shares);
    }
}

/**
 *  @title ITestnetParetoStrategy @notice Interface for native Pareto fixed-value withdrawal receipt issuance.
 */
interface ITestnetParetoStrategy is IParetoCreditVault {
    /**
     * @notice Emitted when the owning CDO is configured.
     */
    event SetCdo(address indexed cdo);

    /**
     * @notice Configures the owning CDO once.
     */
    function setCdo(address newCdo) external;
    /**
     * @notice Issues withdrawal receipts only through the owning CDO.
     */
    function mint(address receiver, uint256 amount) external;
    /**
     * @notice Burns withdrawal receipts only through the owning CDO.
     */
    function burn(address account, uint256 amount) external;
    /**
     * @notice Advances the native epoch counter only through the owning CDO.
     */
    function advanceEpoch() external;
}

/// @title TestnetParetoStrategy
/// @notice Pareto fixed-value strategy receipt with a CDO-controlled epoch counter and supply.
contract TestnetParetoStrategy is ERC20, Ownable, ITestnetParetoStrategy {
    error InvalidCaller();
    error InvalidRequest();
    address public idleCDO;
    address public immutable token;
    uint256 public epochNumber = 1;

    constructor(address newAsset, address newOwner)
        ERC20("Testnet Pareto withdrawal receipt", "FX-RECEIPT")
        Ownable(newOwner)
    {
        token = newAsset;
    }

    /// @inheritdoc ITestnetParetoStrategy
    function setCdo(address newCdo) public onlyOwner {
        if (idleCDO != address(0) || newCdo == address(0)) revert InvalidRequest();
        idleCDO = newCdo;
        emit SetCdo(newCdo);
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(token).decimals();
    }

    /// @inheritdoc ITestnetParetoStrategy
    function mint(address receiver, uint256 amount) public {
        if (idleCDO != msg.sender) revert InvalidCaller();
        _mint(receiver, amount);
    }

    /// @inheritdoc ITestnetParetoStrategy
    function burn(address account, uint256 amount) public {
        if (idleCDO != msg.sender) revert InvalidCaller();
        _burn(account, amount);
    }

    /// @inheritdoc ITestnetParetoStrategy
    function advanceEpoch() public {
        if (idleCDO != msg.sender) revert InvalidCaller();
        ++epochNumber;
    }
}

/**
 *  @title ITestnetParetoCDO @notice Interface for funded epoch lifecycle, eligibility and native direct receipts.
 */
interface ITestnetParetoCDO is IParetoCDO {
    /**
     * @notice Returns the configured native epoch queue.
     */
    function queue() external view returns (address);
    /**
     * @notice Returns the running epoch's settlement boundary.
     */
    function epochMaturity() external view returns (uint256);
    /**
     * @notice Returns direct receipt assets reserved for an account.
     */
    function directRequests(address account) external view returns (uint256);
    /**
     * @notice Returns total actual cash reserved for direct withdrawal receipts.
     */
    function directReserved() external view returns (uint256);
    /**
     * @notice Emitted when native withdrawal eligibility is updated.
     */
    event SetWalletAllowed(address indexed account, bool allowed);
    /**
     * @notice Emitted when the native queue is configured.
     */
    event SetQueue(address indexed queue);
    /**
     * @notice Emitted when native credit default state changes.
     */
    event SetDefaulted(bool defaulted);

    /**
     * @notice Emitted when the operator begins a timed epoch.
     */
    event StartEpoch(uint256 epoch, uint256 maturity);
    /**
     * @notice Emitted when a matured epoch completes after real cash repayment.
     */
    event StopEpoch(uint256 epoch);
    /**
     * @notice Emitted when an account exchanges tranche tokens for a direct receipt.
     */
    event RequestWithdraw(address indexed account, uint256 shares, uint256 assets);
    /**
     * @notice Emitted when direct strategy receipt cash is paid.
     */
    event ClaimWithdrawRequest(address indexed account, uint256 assets);
    /**
     * @notice Changes native wallet eligibility.
     */
    function setWalletAllowed(address account, bool allowed) external;
    /**
     * @notice Configures the unique epoch queue once.
     */
    function setQueue(address newQueue) external;
    /**
     * @notice Starts a seven-day epoch.
     */
    function startEpoch() external;
    /**
     * @notice Ends a matured epoch and advances the strategy epoch counter.
     */
    function stopEpoch() external;
    /**
     * @notice Sets explicit credit default state, causing the actual Pareto oracle to report zero.
     */
    function setDefaulted(bool newDefaulted) external;
}

/// @title TestnetParetoCDO
/// @notice Pareto CDO model with a genuinely backed AA tranche, wallet eligibility, timed epochs and direct receipts.
contract TestnetParetoCDO is Ownable, ITestnetParetoCDO {
    using SafeERC20 for IERC20;
    error InvalidCaller();
    error InvalidRequest();
    error NotMature();
    address public immutable token;
    address public immutable AATranche;
    address public immutable strategy;
    address public queue;
    bool public defaulted;
    bool public isEpochRunning;
    uint256 public epochMaturity;
    mapping(address account => bool allowed) internal _allowed;
    mapping(address account => uint256 assets) public directRequests;
    uint256 public directReserved;

    constructor(address newAsset, address newTranche, address newStrategy, address newOwner) Ownable(newOwner) {
        token = newAsset;
        AATranche = newTranche;
        strategy = newStrategy;
    }

    /// @inheritdoc IParetoCDO
    function strategyToken() public view returns (address) {
        return strategy;
    }

    /// @inheritdoc IParetoCDO
    function oneToken() public view returns (uint256) {
        return 10 ** IERC20Metadata(token).decimals();
    }

    /// @inheritdoc IParetoCDO
    function ONE_TRANCHE_TOKEN() public pure returns (uint256) {
        return 1e18;
    }

    /// @inheritdoc IParetoCDO
    function keyring() public pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IParetoCDO
    function keyringPolicyId() public pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IParetoCDO
    function isWalletAllowed(address account) public view returns (bool) {
        return _allowed[account];
    }

    /// @inheritdoc ITestnetParetoCDO
    function setWalletAllowed(address account, bool allowed) public onlyOwner {
        _allowed[account] = allowed;
        emit SetWalletAllowed(account, allowed);
    }

    /// @inheritdoc ITestnetParetoCDO
    function setQueue(address newQueue) public onlyOwner {
        if (queue != address(0) || newQueue == address(0)) revert InvalidRequest();
        queue = newQueue;
        emit SetQueue(newQueue);
    }

    /// @inheritdoc IParetoCDO
    function virtualPrice(address tranche) public view returns (uint256) {
        if (tranche != AATranche) revert InvalidRequest();
        return IERC4626(AATranche).convertToAssets(1e18);
    }

    /// @inheritdoc ITestnetParetoCDO
    function startEpoch() public onlyOwner {
        if (isEpochRunning || defaulted) revert InvalidRequest();
        isEpochRunning = true;
        epochMaturity = block.timestamp + 7 days;
        emit StartEpoch(IParetoCreditVault(strategy).epochNumber(), epochMaturity);
    }

    /// @inheritdoc ITestnetParetoCDO
    function stopEpoch() public onlyOwner {
        if (!isEpochRunning) revert InvalidRequest();
        if (block.timestamp < epochMaturity) revert NotMature();
        isEpochRunning = false;
        ITestnetParetoStrategy(strategy).advanceEpoch();
        emit StopEpoch(IParetoCreditVault(strategy).epochNumber());
    }

    /// @inheritdoc ITestnetParetoCDO
    function setDefaulted(bool newDefaulted) public onlyOwner {
        defaulted = newDefaulted;
        emit SetDefaulted(newDefaulted);
    }

    /// @inheritdoc IParetoCDO
    function requestWithdraw(uint256 shares, address tranche) public returns (uint256 assets) {
        if (!_allowed[msg.sender] || isEpochRunning || defaulted || tranche != AATranche || shares == 0) {
            revert InvalidRequest();
        }
        IERC20(AATranche).safeTransferFrom(msg.sender, address(this), shares);
        assets = IERC4626(AATranche).redeem(shares, address(this), address(this));
        directRequests[msg.sender] += assets;
        directReserved += assets;
        ITestnetParetoStrategy(strategy).mint(msg.sender, assets);
        emit RequestWithdraw(msg.sender, shares, assets);
    }

    /// @inheritdoc IParetoCDO
    function claimWithdrawRequest() public {
        if (isEpochRunning || defaulted || directRequests[msg.sender] == 0) revert InvalidRequest();
        uint256 assets = directRequests[msg.sender];
        delete directRequests[msg.sender];
        directReserved -= assets;
        ITestnetParetoStrategy(strategy).burn(msg.sender, assets);
        IERC20(token).safeTransfer(msg.sender, assets);
        emit ClaimWithdrawRequest(msg.sender, assets);
    }

    /// @inheritdoc IParetoCDO
    function claimInstantWithdrawRequest() public {
        claimWithdrawRequest();
    }
}

/**
 *  @title ITestnetParetoQueue @notice Interface for timed epoch batching with separate processing and funded settlement.
 */
interface ITestnetParetoQueue is IParetoWithdrawalQueue {
    /**
     * @notice Returns tranche shares queued for one epoch.
     */
    function epochShares(uint256 epoch) external view returns (uint256);
    /**
     * @notice Returns whether an epoch's fixed liabilities have received real cash.
     */
    function settled(uint256 epoch) external view returns (bool);

    /**
     * @notice Emitted when tranche tokens are escrowed in the next epoch.
     */
    event RequestWithdraw(address indexed account, uint256 epoch, uint256 shares);
    /**
     * @notice Emitted when an epoch snapshots its tranche NAV into a fixed asset price.
     */
    event ProcessEpoch(uint256 epoch, uint256 price, uint256 assets);
    /**
     * @notice Emitted when actual tranche backing is redeemed into queue cash.
     */
    event SettleEpoch(uint256 epoch, uint256 assets);
    /**
     * @notice Emitted when a settled epoch pays a request holder.
     */
    event ClaimWithdrawRequest(address indexed account, uint256 epoch, uint256 assets);
    /**
     * @notice Snapshots completed-epoch NAV without making unpaid cash claimable.
     */
    function processEpoch(uint256 epoch) external;
    /**
     * @notice Redeems escrowed tranche backing into actual queue cash for one processed epoch.
     */
    function settleEpoch(uint256 epoch) external;
}

/// @title TestnetParetoQueue
/// @notice Native Pareto epoch queue separating tranche escrow, fixed pricing, cash repayment, and holder claims.
contract TestnetParetoQueue is Ownable, ITestnetParetoQueue {
    using SafeERC20 for IERC20;
    using Math for uint256;
    error InvalidRequest();
    address public immutable idleCDOEpoch;
    address public immutable strategy;
    address public immutable tranche;
    address public immutable underlying;
    mapping(address account => mapping(uint256 epoch => uint256 shares)) public userWithdrawalsEpochs;
    mapping(uint256 epoch => uint256 price) public epochWithdrawPrice;
    mapping(uint256 epoch => uint256 assets) public epochPendingClaims;
    mapping(uint256 epoch => uint256 shares) public epochShares;
    mapping(uint256 epoch => bool status) public settled;

    constructor(address newCdo, address newOwner) Ownable(newOwner) {
        idleCDOEpoch = newCdo;
        strategy = IParetoCDO(newCdo).strategy();
        tranche = IParetoCDO(newCdo).AATranche();
        underlying = IParetoCDO(newCdo).token();
    }

    /// @inheritdoc IParetoWithdrawalQueue
    function requestWithdraw(uint256 shares) public {
        if (
            shares == 0 || !IParetoCDO(idleCDOEpoch).isEpochRunning()
                || !IParetoCDO(idleCDOEpoch).isWalletAllowed(msg.sender) || IParetoCDO(idleCDOEpoch).defaulted()
        ) revert InvalidRequest();
        uint256 epoch = IParetoCreditVault(strategy).epochNumber() + 1;
        IERC20(tranche).safeTransferFrom(msg.sender, address(this), shares);
        userWithdrawalsEpochs[msg.sender][epoch] += shares;
        epochShares[epoch] += shares;
        emit RequestWithdraw(msg.sender, epoch, shares);
    }

    /// @inheritdoc ITestnetParetoQueue
    function processEpoch(uint256 epoch) public onlyOwner {
        if (
            epochShares[epoch] == 0 || epochWithdrawPrice[epoch] > 0
                || IParetoCreditVault(strategy).epochNumber() < epoch || IParetoCDO(idleCDOEpoch).isEpochRunning()
        ) revert InvalidRequest();
        uint256 price = IParetoCDO(idleCDOEpoch).virtualPrice(tranche);
        if (price == 0) revert InvalidRequest();
        epochWithdrawPrice[epoch] = price;
        epochPendingClaims[epoch] = epochShares[epoch].mulDiv(price, 1e18);
        emit ProcessEpoch(epoch, price, epochPendingClaims[epoch]);
    }

    /// @inheritdoc ITestnetParetoQueue
    function settleEpoch(uint256 epoch) public onlyOwner {
        if (epochWithdrawPrice[epoch] == 0 || settled[epoch]) revert InvalidRequest();
        // Withdraw the fixed processed value, burning the required shares at the current NAV.
        // The model forbids any further loan deployment after pricing until settlement in its runbook.
        uint256 assets = epochPendingClaims[epoch];
        uint256 shares = IERC4626(tranche).withdraw(assets, address(this), address(this));
        if (shares > epochShares[epoch]) revert InvalidRequest();
        settled[epoch] = true;
        epochPendingClaims[epoch] = 0;
        emit SettleEpoch(epoch, assets);
    }

    /// @inheritdoc IParetoWithdrawalQueue
    function claimWithdrawRequest(uint256 epoch) public {
        uint256 shares = userWithdrawalsEpochs[msg.sender][epoch];
        if (shares == 0 || !settled[epoch] || epochPendingClaims[epoch] > 0) revert InvalidRequest();
        delete userWithdrawalsEpochs[msg.sender][epoch];
        uint256 assets = shares.mulDiv(epochWithdrawPrice[epoch], 1e18);
        IERC20(underlying).safeTransfer(msg.sender, assets);
        emit ClaimWithdrawRequest(msg.sender, epoch, assets);
    }
}

/**
 *  @title ITestnetYieldDeploymentScript @notice Interface for deploying every non-issuer native yield redemption profile.
 */
interface ITestnetYieldDeploymentScript {
    /**
     * @notice Returns the model operator and inventory owner.
     */
    function owner() external view returns (address);
    /**
     * @notice Returns whether Foundry sends transactions or runs local owner pranks.
     */
    function broadcast() external view returns (bool);
    /**
     * @notice Deposits actual owner assets through the native protocol layers into receiver shares.
     */
    function seed(address token, address endpoint, uint8 profile, uint256 assets, address receiver)
        external
        returns (uint256 shares);

    /**
     * @notice Raised when a token profile is outside the supported integrations.
     */
    error InvalidProfile();
    /**
     * @notice Deploys funded native protocol topology, its actual family oracle, and a configurable production account.
     * @dev Profiles: PRIME=0, AUTO=1, AA_FalconX=10. Endpoint identifies the request/settlement entrypoint;
     * deposit tokens are always issued through actual asset deposits, never privileged minting.
     */
    function deploy(address factory, address cow, address asset, uint8 profile)
        external
        returns (address token, address oracle, address endpoint, address implementation);
}

/// @title TestnetYieldDeploymentScript
/// @notice Foundry-only deployment helper keeping large creation bytecode offchain while deploying real account implementations.
contract TestnetYieldDeploymentScript is Script, ITestnetYieldDeploymentScript {
    address public immutable owner;
    bool public immutable broadcast;

    constructor(address newOwner, bool newBroadcast) {
        owner = newOwner;
        broadcast = newBroadcast;
    }

    /// @inheritdoc ITestnetYieldDeploymentScript
    function seed(address token, address endpoint, uint8 profile, uint256 assets, address receiver)
        public
        returns (uint256 shares)
    {
        if (profile > 1 && profile != 10) revert InvalidProfile();
        if (broadcast) vm.startBroadcast(owner);
        else vm.startPrank(owner);
        if (profile < 2) {
            address underlying = IERC4626(endpoint).asset();
            IERC20(underlying).approve(endpoint, assets);
            uint256 underlyingShares = IERC4626(endpoint).deposit(assets, owner);
            IERC20(endpoint).approve(token, underlyingShares);
            shares = IERC4626(token).deposit(underlyingShares, receiver);
        } else {
            IERC20(IERC4626(token).asset()).approve(token, assets);
            shares = IERC4626(token).deposit(assets, receiver);
        }
        if (broadcast) vm.stopBroadcast();
        else vm.stopPrank();
    }

    /// @inheritdoc ITestnetYieldDeploymentScript
    function deploy(address factory, address cow, address asset, uint8 profile)
        public
        returns (address token, address oracle, address endpoint, address implementation)
    {
        if (profile > 1 && profile != 10) revert InvalidProfile();
        if (broadcast) vm.startBroadcast(owner);
        else vm.startPrank(owner);
        if (profile < 2) {
            endpoint = address(new TestnetFigureYieldVault(asset, owner));
            token = address(
                new TestnetYieldVault(
                    endpoint,
                    owner,
                    profile == 0 ? "Testnet Hastra PRIME" : "Testnet Hastra AUTO",
                    profile == 0 ? "PRIME" : "AUTO",
                    IERC20Metadata(endpoint).decimals()
                )
            );
            oracle = address(new FigureOracle(0.5e18, 2.5e18, token));
            address subAccount = address(new FigureSubAccount(token));
            implementation =
                address(new FigureAccount(oracle, factory, profile == 0 ? 18 hours : 1 days, token, subAccount, cow));
        } else {
            token = address(new TestnetParetoTranche(asset, owner));
            address strategy = address(new TestnetParetoStrategy(asset, owner));
            address cdo = address(new TestnetParetoCDO(asset, token, strategy, owner));
            TestnetParetoStrategy(strategy).setCdo(cdo);
            endpoint = address(new TestnetParetoQueue(cdo, owner));
            TestnetParetoCDO(cdo).setQueue(endpoint);
            TestnetParetoTranche(token).setEndpoints(cdo, endpoint);
            oracle = address(new ParetoOracle(0.5e18, 2.5e18, token, cdo));
            implementation = address(new ParetoAccount(oracle, factory, token, endpoint, cow));
        }
        if (broadcast) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
