// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ChainlinkOracle} from "../../../../src/contracts/ll-adapter/oracles/ChainlinkOracle.sol";
import {ERC4626Oracle} from "../../../../src/contracts/ll-adapter/oracles/ERC4626Oracle.sol";
import {FigureAccount, FigureSubAccount} from "../../../../src/contracts/ll-adapter/FigureAccount.sol";
import {FigureOracle} from "../../../../src/contracts/ll-adapter/oracles/FigureOracle.sol";
import {GaibAccount} from "../../../../src/contracts/ll-adapter/GaibAccount.sol";
import {InfiniFiAccount} from "../../../../src/contracts/ll-adapter/InfiniFiAccount.sol";
import {MakinaAccount} from "../../../../src/contracts/ll-adapter/MakinaAccount.sol";
import {MakinaOracle} from "../../../../src/contracts/ll-adapter/oracles/MakinaOracle.sol";
import {NoonAccount} from "../../../../src/contracts/ll-adapter/NoonAccount.sol";
import {NoonRateProviderOracle} from "../../../../src/contracts/ll-adapter/oracles/NoonRateProviderOracle.sol";
import {ParetoAccount} from "../../../../src/contracts/ll-adapter/ParetoAccount.sol";
import {ParetoOracle} from "../../../../src/contracts/ll-adapter/oracles/ParetoOracle.sol";
import {SThreeJaneAccount} from "../../../../src/contracts/ll-adapter/SThreeJaneAccount.sol";
import {SThreeJaneOracle} from "../../../../src/contracts/ll-adapter/oracles/SThreeJaneOracle.sol";
import {SaidOracle} from "../../../../src/contracts/ll-adapter/oracles/SaidOracle.sol";
import {TheoAccount} from "../../../../src/contracts/ll-adapter/TheoAccount.sol";
import {ThreeJaneAccount} from "../../../../src/contracts/ll-adapter/ThreeJaneAccount.sol";
import {ThreeJaneOracle} from "../../../../src/contracts/ll-adapter/oracles/ThreeJaneOracle.sol";

import {IFigureYieldVault} from "../../../../src/interfaces/ll-adapter/figure/IFigureYieldVault.sol";
import {IInfiniFiGateway} from "../../../../src/interfaces/ll-adapter/infinifi/IInfiniFiGateway.sol";
import {IInfiniFiUnwindingModule} from "../../../../src/interfaces/ll-adapter/infinifi/IInfiniFiUnwindingModule.sol";
import {IMakinaMachine} from "../../../../src/interfaces/ll-adapter/makina/IMakinaMachine.sol";
import {IMakinaRedeemer} from "../../../../src/interfaces/ll-adapter/makina/IMakinaRedeemer.sol";
import {INoonWithdrawalHandler} from "../../../../src/interfaces/ll-adapter/noon/INoonWithdrawalHandler.sol";
import {IParetoCDO} from "../../../../src/interfaces/ll-adapter/pareto/IParetoCDO.sol";
import {IParetoCreditVault} from "../../../../src/interfaces/ll-adapter/pareto/IParetoCreditVault.sol";
import {IParetoWithdrawalQueue} from "../../../../src/interfaces/ll-adapter/pareto/IParetoWithdrawalQueue.sol";
import {ISThreeJaneSUSD3} from "../../../../src/interfaces/ll-adapter/sthreejane/ISThreeJaneSUSD3.sol";
import {ISaid} from "../../../../src/interfaces/ll-adapter/gaib/ISaid.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
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
 *  @title ITestnetMakinaMachine @notice Interface for Makina's accounting and share-price publication model.
 */
interface ITestnetMakinaMachine is IMakinaMachine {
    /**
     * @notice Returns the sole native receipt redemption endpoint.
     */
    function redeemer() external view returns (address);
    /**
     * @notice Emitted when the native redeemer is configured once.
     */
    event SetRedeemer(address indexed redeemer);

    /**
     * @notice Emitted when machine NAV is checkpointed for the share-price oracle.
     */
    event UpdateAccounting(uint256 price, uint256 timestamp);
    /**
     * @notice Returns the share-price feed denomination.
     */
    function decimals() external view returns (uint8);
    /**
     * @notice Returns share price in the feed denomination.
     */
    function getSharePrice() external view returns (uint256);
    /**
     * @notice Configures the unique native redemption endpoint once.
     */
    function setRedeemer(address newRedeemer) external;
    /**
     * @notice Checkpoints live funded NAV and publishes a fresh accounting timestamp.
     */
    function updateAccounting() external;
}

/// @title TestnetMakinaMachine
/// @notice DUSD credit machine with funded share issuance and an explicit NAV accounting checkpoint.
contract TestnetMakinaMachine is TestnetYieldVault, ITestnetMakinaMachine {
    using Math for uint256;
    /* STATE VARIABLES */
    uint256 public lastGlobalAccountingTime;
    uint256 internal _publishedPrice = 1e18;
    address public redeemer;

    /* CONSTRUCTOR */
    constructor(address newAsset, address newOwner)
        TestnetYieldVault(newAsset, newOwner, "Testnet Makina dollar", "DUSD", 18)
    {
        lastGlobalAccountingTime = block.timestamp;
    }

    /* PUBLIC FUNCTIONS */
    /// @inheritdoc ITestnetMakinaMachine
    function decimals() public view override(ERC4626, IERC20Metadata, ITestnetMakinaMachine) returns (uint8) {
        return super.decimals();
    }

    /// @inheritdoc IMakinaMachine
    function accountingToken() public view returns (address) {
        return asset();
    }

    /// @inheritdoc ITestnetMakinaMachine
    function getSharePrice() public view returns (uint256) {
        return _publishedPrice;
    }

    /// @inheritdoc ITestnetMakinaMachine
    function setRedeemer(address newRedeemer) public onlyOwner {
        if (redeemer != address(0) || newRedeemer == address(0)) revert InvalidRequest();
        redeemer = newRedeemer;
        emit SetRedeemer(newRedeemer);
    }

    /// @inheritdoc ITestnetMakinaMachine
    function updateAccounting() public onlyOwner {
        _publishedPrice = (totalAssets() + 1).mulDiv(1e18 * 10 ** _OFFSET, totalSupply() + 10 ** _OFFSET);
        lastGlobalAccountingTime = block.timestamp;
        emit UpdateAccounting(_publishedPrice, block.timestamp);
    }

    function _withdraw(address caller, address receiver, address account, uint256 assets, uint256 shares)
        internal
        override
    {
        if (redeemer != caller || redeemer != receiver || redeemer != account) revert InvalidCaller();
        super._withdraw(caller, receiver, account, assets, shares);
    }
}

/**
 *  @title ITestnetMakinaRedeemer @notice Interface for funded NFT-receipt redemption settlement.
 */
interface ITestnetMakinaRedeemer is IMakinaRedeemer {
    /**
     * @notice Returns escrow shares, minimum proceeds, settled assets, request timestamp, and settlement state.
     */
    function requests(uint256 id)
        external
        view
        returns (uint256 shares, uint256 minAssets, uint256 assets, uint48 timestamp, bool finalized);

    /**
     * @notice Emitted when deposited shares are escrowed and a receipt NFT is created.
     */
    event RequestRedeem(uint256 indexed requestId, address indexed receiver, uint256 shares);
    /**
     * @notice Emitted when escrowed shares are redeemed into actual cash.
     */
    event Finalize(uint256 indexed requestId, uint256 assets);
    /**
     * @notice Emitted when an owner claims cash and the receipt NFT is destroyed.
     */
    event ClaimAssets(uint256 indexed requestId, uint256 assets);
    /**
     * @notice Converts a matured receipt's shares to cash using the real machine vault.
     */
    function finalize(uint256 requestId) external;
    /**
     * @notice Returns the next unique receipt identifier.
     */
    function nextRequestId() external view returns (uint256);
}

/// @title TestnetMakinaRedeemer
/// @notice Makina redemption NFT model with escrow, NAV-dependent settlement, minimum proceeds, and replay protection.
contract TestnetMakinaRedeemer is ERC721, Ownable, ITestnetMakinaRedeemer {
    using SafeERC20 for IERC20;
    error InvalidAmount();
    error InvalidCaller();
    error InvalidRequest();
    error NotMature();

    struct Request {
        uint256 shares;
        uint256 minAssets;
        uint256 assets;
        uint48 timestamp;
        bool finalized;
    }
    address public immutable machine;
    uint256 public nextRequestId = 1;
    mapping(uint256 id => Request request) public requests;

    constructor(address newMachine, address newOwner)
        ERC721("Testnet Makina redemption", "DUSD-REDEEM")
        Ownable(newOwner)
    {
        machine = newMachine;
    }

    /// @inheritdoc IMakinaRedeemer
    function getShares(uint256 id) public view returns (uint256) {
        ownerOf(id);
        return requests[id].shares;
    }

    /// @inheritdoc IMakinaRedeemer
    function getClaimableAssets(uint256 id) public view returns (uint256) {
        ownerOf(id);
        if (!requests[id].finalized) revert InvalidRequest();
        return requests[id].assets;
    }

    /// @inheritdoc IMakinaRedeemer
    function requestRedeem(uint256 shares, address receiver, uint256 minAssets) public returns (uint256 id) {
        if (shares == 0 || receiver == address(0)) revert InvalidAmount();
        id = nextRequestId++;
        IERC20(machine).safeTransferFrom(msg.sender, address(this), shares);
        requests[id] = Request({
            shares: shares, minAssets: minAssets, assets: 0, timestamp: uint48(block.timestamp), finalized: false
        });
        _safeMint(receiver, id);
        emit RequestRedeem(id, receiver, shares);
    }

    /// @inheritdoc ITestnetMakinaRedeemer
    function finalize(uint256 id) public onlyOwner {
        ownerOf(id);
        Request storage request = requests[id];
        if (request.finalized) revert InvalidRequest();
        if (block.timestamp < request.timestamp + 2 days) revert NotMature();
        uint256 assets = IERC4626(machine).redeem(request.shares, address(this), address(this));
        if (assets < request.minAssets) revert InvalidAmount();
        request.assets = assets;
        request.finalized = true;
        emit Finalize(id, assets);
    }

    /// @inheritdoc IMakinaRedeemer
    function claimAssets(uint256 id) public returns (uint256 assets) {
        if (ownerOf(id) != msg.sender) revert InvalidCaller();
        assets = getClaimableAssets(id);
        _burn(id);
        delete requests[id];
        IERC20(IMakinaMachine(machine).accountingToken()).safeTransfer(msg.sender, assets);
        emit ClaimAssets(id, assets);
    }
}

/**
 *  @title ITestnetSaid @notice Interface for FIFO unstaking settlement administration.
 */
interface ITestnetSaid is ISaid {
    /**
     * @notice Returns a queue holder by index.
     */
    function queue(uint256 index) external view returns (address);
    /**
     * @notice Returns the next queue item eligible for processing.
     */
    function queueHead() external view returns (uint256);
    /**
     * @notice Returns a holder's unstaking timestamp, pending assets and processing eligibility.
     */
    function unstakeRequests(address account) external view returns (uint256 timestamp, uint256 assets, bool finalized);

    /**
     * @notice Emitted when a holder opens a loss-aware unstake request.
     */
    event Unstake(address indexed account, uint256 shares, uint256 assets);
    /**
     * @notice Emitted when the owner makes a matured cash-backed request processable.
     */
    event Finalize(address indexed account);
    /**
     * @notice Emitted when queue cash is transferred to a request holder.
     */
    event ProcessUnstakeQueue(address indexed account, uint256 assets);
    /**
     * @notice Enables processing of a matured, fully cash-backed unstake slot.
     */
    function finalize(address account) external;
}

/// @title TestnetSaid
/// @notice GAIB loss-aware sAID vault model with a global FIFO unstake queue and funded admin finalization.
contract TestnetSaid is TestnetYieldVault, ITestnetSaid {
    struct Request {
        uint256 timestamp;
        uint256 assets;
        bool finalized;
    }
    mapping(address account => Request request) public unstakeRequests;
    address[] public queue;
    uint256 public queueHead;

    constructor(address newAsset, address newOwner)
        TestnetYieldVault(newAsset, newOwner, "Testnet Staked AID", "sAID", 18)
    {}

    /// @inheritdoc ISaid
    function convertToAssetsWithLoss(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @inheritdoc ISaid
    function getUnstakeRequest(address account) public view returns (uint256 timestamp, uint256 assets) {
        Request storage request = unstakeRequests[account];
        return (request.timestamp, request.assets);
    }

    /// @inheritdoc ISaid
    function unstake(uint256 shares) public {
        if (unstakeRequests[msg.sender].assets > 0) revert InvalidRequest();
        uint256 assets = _reserve(msg.sender, shares);
        unstakeRequests[msg.sender] = Request({timestamp: block.timestamp, assets: assets, finalized: false});
        queue.push(msg.sender);
        emit Unstake(msg.sender, shares, assets);
    }

    /// @inheritdoc ITestnetSaid
    function finalize(address account) public onlyOwner {
        Request storage request = unstakeRequests[account];
        if (request.assets == 0 || request.finalized) revert InvalidRequest();
        if (block.timestamp < request.timestamp + 2 days) revert NotMature();
        if (cash() < reservedAssets) revert InvalidAmount();
        request.finalized = true;
        emit Finalize(account);
    }

    /// @inheritdoc ISaid
    function processUnstakeQueue(uint256 maxIterations) public {
        uint256 length = queue.length;
        for (uint256 i; i < maxIterations && queueHead < length; ++i) {
            address account = queue[queueHead];
            Request memory request = unstakeRequests[account];
            if (!request.finalized) break;
            ++queueHead;
            delete unstakeRequests[account];
            _payReserve(account, request.assets);
            emit ProcessUnstakeQueue(account, request.assets);
        }
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
 *  @title ITestnetSUSD3 @notice Interface for cooldown windows of the funded USD3 staking vault.
 */
interface ITestnetSUSD3 is ISThreeJaneSUSD3 {
    /**
     * @notice Returns the cooldown boundary, closing boundary and remaining authorized shares.
     */
    function cooldowns(address account) external view returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);

    /**
     * @notice Emitted when a withdrawal cooldown begins or restarts after an expired window.
     */
    event StartCooldown(address indexed account, uint256 shares, uint256 cooldownEnd, uint256 windowEnd);
}

/// @title TestnetSUSD3
/// @notice sUSD3 ERC-4626 vault holding actual USD3 with a seven-day cooldown and two-day withdrawal window.
contract TestnetSUSD3 is TestnetYieldVault, ITestnetSUSD3 {
    struct Cooldown {
        uint256 cooldownEnd;
        uint256 windowEnd;
        uint256 shares;
    }
    mapping(address account => Cooldown status) public cooldowns;

    constructor(address newUsd3, address newOwner)
        TestnetYieldVault(newUsd3, newOwner, "Testnet staked USD3", "sUSD3", 18)
    {}

    /// @inheritdoc ISThreeJaneSUSD3
    function getCooldownStatus(address account) public view returns (uint256, uint256, uint256) {
        Cooldown storage status = cooldowns[account];
        return (status.cooldownEnd, status.windowEnd, status.shares);
    }

    /// @inheritdoc ISThreeJaneSUSD3
    function startCooldown(uint256 shares) public {
        if (shares == 0 || shares > balanceOf(msg.sender)) revert InvalidAmount();
        if (block.timestamp <= cooldowns[msg.sender].windowEnd) revert InvalidRequest();
        cooldowns[msg.sender] =
            Cooldown({cooldownEnd: block.timestamp + 7 days, windowEnd: block.timestamp + 9 days, shares: shares});
        emit StartCooldown(msg.sender, shares, block.timestamp + 7 days, block.timestamp + 9 days);
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address account) public view override returns (uint256) {
        Cooldown storage status = cooldowns[account];
        if (block.timestamp < status.cooldownEnd || block.timestamp > status.windowEnd) return 0;
        return Math.min(super.maxWithdraw(account), convertToAssets(status.shares));
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address account) public view override returns (uint256) {
        Cooldown storage status = cooldowns[account];
        if (block.timestamp < status.cooldownEnd || block.timestamp > status.windowEnd) return 0;
        return Math.min(super.maxRedeem(account), status.shares);
    }

    function _withdraw(address caller, address receiver, address account, uint256 assets, uint256 shares)
        internal
        override
    {
        cooldowns[account].shares -= shares;
        super._withdraw(caller, receiver, account, assets, shares);
    }
}

/**
 *  @title ITestnetTheoVault @notice Interface for one-slot asynchronous Theo redemption requests.
 */
interface ITestnetTheoVault {
    /**
     * @notice Emitted when shares are burned into a reserved claim with a fixed maturity.
     */
    event InitiateRedeem(address indexed account, uint256 shares, uint256 assets, uint256 claimableTimestamp);
    /**
     * @notice Returns the owner's reserved assets, request shares, and maturity timestamp.
     */
    function currentRedeemRequest(address account)
        external
        view
        returns (uint256 assets, uint256 shares, uint256 claimableTimestamp);
    /**
     * @notice Burns held shares into the owner's unique asynchronous request.
     */
    function initiateRedeem(uint256 shares, address account) external;
}

/// @title TestnetTheoVault
/// @notice Funded sthUSD model with burned-share request custody, cash settlement and seven-day maturity.
contract TestnetTheoVault is TestnetYieldVault, ITestnetTheoVault {
    struct Request {
        uint256 assets;
        uint256 shares;
        uint256 claimableTimestamp;
    }
    mapping(address account => Request request) public currentRedeemRequest;

    constructor(address newAsset, address newOwner)
        TestnetYieldVault(newAsset, newOwner, "Testnet staked thUSD", "sthUSD", 18)
    {}

    /// @inheritdoc ITestnetTheoVault
    function initiateRedeem(uint256 shares, address account) public {
        if (account != msg.sender) revert InvalidCaller();
        if (currentRedeemRequest[account].shares > 0) revert InvalidRequest();
        uint256 assets = _reserve(account, shares);
        currentRedeemRequest[account] =
            Request({assets: assets, shares: shares, claimableTimestamp: block.timestamp + 7 days});
        emit InitiateRedeem(account, shares, assets, block.timestamp + 7 days);
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address account)
        public
        override(ERC4626, IERC4626)
        returns (uint256 assets)
    {
        if (account != msg.sender) revert InvalidCaller();
        Request memory request = currentRedeemRequest[account];
        if (shares == 0 || shares != request.shares) revert InvalidRequest();
        if (block.timestamp < request.claimableTimestamp) revert NotMature();
        delete currentRedeemRequest[account];
        assets = request.assets;
        _payReserve(receiver, assets);
        emit Withdraw(msg.sender, receiver, account, assets, shares);
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
 *  @title ITestnetNoonHandler @notice Interface for native Noon custody and owner settlement.
 */
interface ITestnetNoonHandler is INoonWithdrawalHandler {
    /**
     * @notice Returns the authorized sUSN vault.
     */
    function vault() external view returns (address);
    /**
     * @notice Returns total USN custody committed to request holders.
     */
    function reservedAssets() external view returns (uint256);
    /**
     * @notice Returns whether a user's request has received admin settlement approval.
     */
    function finalized(address account, uint256 id) external view returns (bool);
    /**
     * @notice Emitted when the unique vault is configured.
     */
    event SetVault(address indexed vault);

    /**
     * @notice Emitted when sUSN redemption transfers actual USN into the handler.
     */
    event Record(address indexed account, uint256 indexed id, uint256 amount);
    /**
     * @notice Emitted when the owner approves a matured, cash-backed request.
     */
    event Finalize(address indexed account, uint256 indexed id);
    /**
     * @notice Emitted when matured USN custody is paid to its request owner.
     */
    event ClaimWithdrawal(address indexed account, uint256 indexed id, uint256 amount);
    /**
     * @notice Creates the next request after the configured sUSN vault transfers its cash.
     */
    function record(address account, uint256 amount) external;
    /**
     * @notice Configures the unique authorized vault once.
     */
    function setVault(address newVault) external;
    /**
     * @notice Finalizes an existing matured request held in fully funded custody.
     */
    function finalize(address account, uint256 id) external;
}

/// @title TestnetNoonHandler
/// @notice Noon withdrawal handler with per-user request IDs, two-day admin settlement, and escrowed USN cash.
contract TestnetNoonHandler is Ownable, ITestnetNoonHandler {
    using SafeERC20 for IERC20;
    error InvalidAmount();
    error InvalidCaller();
    error InvalidRequest();
    error NotMature();
    address public immutable usn;
    uint256 public immutable withdrawPeriod = 2 days;
    address public vault;
    uint256 public reservedAssets;
    mapping(address account => uint256 nextId) public getUserNextRequestId;
    mapping(address account => mapping(uint256 id => WithdrawalRequest request)) internal _requests;
    mapping(address account => mapping(uint256 id => bool ready)) public finalized;

    constructor(address newUsn, address newOwner) Ownable(newOwner) {
        usn = newUsn;
    }

    /// @inheritdoc ITestnetNoonHandler
    function setVault(address newVault) public onlyOwner {
        if (vault != address(0) || newVault == address(0)) revert InvalidRequest();
        vault = newVault;
        emit SetVault(newVault);
    }

    /// @inheritdoc ITestnetNoonHandler
    function record(address account, uint256 amount) public {
        if (vault != msg.sender) revert InvalidCaller();
        if (amount == 0 || IERC20(usn).balanceOf(address(this)) < reservedAssets + amount) revert InvalidAmount();
        uint256 id = getUserNextRequestId[account]++;
        _requests[account][id] = WithdrawalRequest({amount: amount, timestamp: block.timestamp, claimed: false});
        reservedAssets += amount;
        emit Record(account, id, amount);
    }

    /// @inheritdoc INoonWithdrawalHandler
    function getWithdrawalRequest(address account, uint256 id) public view returns (WithdrawalRequest memory) {
        return _requests[account][id];
    }

    /// @inheritdoc ITestnetNoonHandler
    function finalize(address account, uint256 id) public onlyOwner {
        WithdrawalRequest storage request = _requests[account][id];
        if (request.amount == 0 || request.claimed || finalized[account][id]) revert InvalidRequest();
        if (block.timestamp < request.timestamp + withdrawPeriod) revert NotMature();
        finalized[account][id] = true;
        emit Finalize(account, id);
    }

    /// @inheritdoc INoonWithdrawalHandler
    function claimWithdrawal(uint256 id) public {
        WithdrawalRequest storage request = _requests[msg.sender][id];
        if (request.claimed || request.amount == 0 || !finalized[msg.sender][id]) revert InvalidRequest();
        if (block.timestamp < request.timestamp + withdrawPeriod) revert NotMature();
        request.claimed = true;
        reservedAssets -= request.amount;
        IERC20(usn).safeTransfer(msg.sender, request.amount);
        emit ClaimWithdrawal(msg.sender, id, request.amount);
    }
}

/**
 *  @title ITestnetNoonVault @notice Interface for funded sUSN topology and native rate-provider reads.
 */
interface ITestnetNoonVault {
    /**
     * @notice Returns the configured native withdrawal handler.
     */
    function withdrawalHandler() external view returns (address);
    /**
     * @notice Returns an sUSN-to-USN quote derived from actual funded vault NAV.
     */
    function getQuote(uint256 amount, address base, address quote) external view returns (uint256);
}

/// @title TestnetNoonVault
/// @notice Funded sUSN vault directing native redemption proceeds into its withdrawal handler.
contract TestnetNoonVault is TestnetYieldVault, ITestnetNoonVault {
    address public immutable withdrawalHandler;

    constructor(address newAsset, address newOwner, address newHandler)
        TestnetYieldVault(newAsset, newOwner, "Testnet staked USN", "sUSN", 18)
    {
        withdrawalHandler = newHandler;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address account)
        public
        override(ERC4626, IERC4626)
        returns (uint256 assets)
    {
        if (receiver != withdrawalHandler) revert InvalidCaller();
        assets = super.redeem(shares, receiver, account);
        ITestnetNoonHandler(withdrawalHandler).record(account, assets);
    }

    /// @inheritdoc ITestnetNoonVault
    function getQuote(uint256 amount, address base, address quote) public view returns (uint256) {
        if (base != address(this) || quote != asset()) revert InvalidAmount();
        return convertToAssets(amount);
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert InvalidRequest();
    }
}

/**
 *  @title ITestnetInfiniFi @notice Interface for receipt-backed infiniFi deposits, weekly unwindings and loss administration.
 */
interface ITestnetInfiniFi is IInfiniFiGateway, IInfiniFiUnwindingModule {
    /**
     * @notice Returns the selected native bucket's weekly epoch duration.
     */
    function unwindingEpochs() external view returns (uint32);
    /**
     * @notice Returns explicitly tracked off-vault stable principal.
     */
    function receivable() external view returns (uint256);
    /**
     * @notice Returns current iUSD reserved for unwinding positions.
     */
    function reservedReceipts() external view returns (uint256);
    /**
     * @notice Returns the cumulative queue loss multiplier in 1e18 precision.
     */
    function lossFactor() external view returns (uint256);
    /**
     * @notice Returns a position's pre-multiplier units and aligned maturity timestamp.
     */
    function positions(address account, uint256 timestamp) external view returns (uint256 units, uint256 maturity);
    /**
     * @notice Emitted when stable cash is deployed as credit principal.
     */
    event DeployCapital(address indexed receiver, uint256 assets);
    /**
     * @notice Emitted when funded credit principal returns.
     */
    event RepayCapital(address indexed payer, uint256 assets);

    /**
     * @notice Emitted when stable assets mint genuinely backed iUSD receipts.
     */
    event Deposit(address indexed account, uint256 assets, uint256 receipts);
    /**
     * @notice Emitted when locked shares enter a weekly unwinding position.
     */
    event StartUnwinding(address indexed account, uint256 timestamp, uint256 receipts, uint256 maturity);
    /**
     * @notice Emitted when matured iUSD receipts leave unwinding custody.
     */
    event Withdraw(address indexed account, uint256 timestamp, uint256 receipts);
    /**
     * @notice Emitted when receipts are destroyed in exchange for idle stable cash.
     */
    event Redeem(address indexed account, address indexed receiver, uint256 receipts, uint256 assets);
    /**
     * @notice Emitted when off-vault credit is written down and pending receipts are slashed.
     */
    event ReportLoss(uint256 lossFactor, uint256 assets);
    /**
     * @notice Emitted when protocol loss accounting is acknowledged, enabling native exits.
     */
    event AccrueLoss();
    /**
     * @notice Returns the iUSD receipt token.
     */
    function iusd() external view returns (address);
    /**
     * @notice Returns the liUSD bucket accepted by this gateway.
     */
    function lockedToken() external view returns (address);
    /**
     * @notice Returns the stable backing asset.
     */
    function asset() external view returns (address);
    /**
     * @notice Returns whether loss accounting currently prevents withdrawal and redemption.
     */
    function lossesUnaccrued() external view returns (bool);
    /**
     * @notice Mints iUSD after pulling stable assets from the caller.
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 receipts);
    /**
     * @notice Deploys real stable cash as an explicitly tracked loan.
     */
    function deployCapital(address receiver, uint256 assets) external;
    /**
     * @notice Returns real stable cash and decreases outstanding principal.
     */
    function repayCapital(uint256 assets) external;
    /**
     * @notice Slashes pending receipt value proportionately and writes off corresponding loan principal.
     */
    function reportLoss(uint256 newLossFactor) external;
    /**
     * @notice Acknowledges recorded losses to enable native protocol exits.
     */
    function accrueLoss() external;
}

/**
 *  @title ITestnetIusdReceipt @notice Interface for gateway-controlled, genuinely backed iUSD receipt supply.
 */
interface ITestnetIusdReceipt {
    /**
     * @notice Raised when a caller is not the sole gateway.
     */
    error InvalidCaller();
    /**
     * @notice Returns the sole supply controller.
     */
    function gateway() external view returns (address);
    /**
     * @notice Issues receipt supply after the native gateway has taken stable asset backing.
     */
    function mint(address receiver, uint256 amount) external;
    /**
     * @notice Destroys gateway-owned receipt supply on funded stable exit or recognized loss.
     */
    function burn(uint256 amount) external;
}

/// @title TestnetIusdReceipt
/// @notice Native 18-decimal iUSD receipt whose supply can change only through its backing gateway.
contract TestnetIusdReceipt is ERC20, ITestnetIusdReceipt {
    address public immutable gateway;

    constructor(address newGateway) ERC20("Testnet infiniFi USD", "iUSD") {
        gateway = newGateway;
    }

    /// @inheritdoc ITestnetIusdReceipt
    function mint(address receiver, uint256 amount) public {
        if (gateway != msg.sender) revert InvalidCaller();
        _mint(receiver, amount);
    }

    /// @inheritdoc ITestnetIusdReceipt
    function burn(uint256 amount) public {
        if (gateway != msg.sender) revert InvalidCaller();
        _burn(msg.sender, amount);
    }
}

/**
 *  @title ITestnetInfiniFiLockedVault @notice Interface for the native weekly liUSD gateway topology.
 */
interface ITestnetInfiniFiLockedVault {
    /**
     * @notice Returns the sole native redemption endpoint.
     */
    function gateway() external view returns (address);
}

/// @title TestnetInfiniFiLockedVault
/// @notice Funded liUSD vault allowing native redemptions only through its weekly unwinding gateway.
contract TestnetInfiniFiLockedVault is TestnetYieldVault, ITestnetInfiniFiLockedVault {
    address public immutable gateway;

    constructor(address newIusd, address newOwner, address newGateway, uint32 epochs)
        TestnetYieldVault(newIusd, newOwner, "Testnet locked iUSD", epochs == 4 ? "liUSD4w" : "liUSD13w", 18)
    {
        gateway = newGateway;
    }

    function _withdraw(address caller, address receiver, address account, uint256 assets, uint256 shares)
        internal
        override
    {
        if (gateway != caller || gateway != receiver || gateway != account) revert InvalidCaller();
        super._withdraw(caller, receiver, account, assets, shares);
    }
}

/// @title TestnetInfiniFiGateway
/// @notice Funded iUSD gateway and unwinding module with four/thirteen week buckets, instant-cash gating and real losses.
contract TestnetInfiniFiGateway is Ownable, ITestnetInfiniFi {
    using SafeERC20 for IERC20;
    using Math for uint256;
    error InvalidAmount();
    error InvalidRequest();
    error LossesUnaccrued();
    error NotMature();

    struct Position {
        uint256 units;
        uint256 maturity;
    }
    address public immutable asset;
    address public immutable iusd;
    address public immutable lockedToken;
    uint32 public immutable unwindingEpochs;
    uint256 public receivable;
    uint256 public reservedReceipts;
    uint256 public lossFactor = 1e18;
    bool public lossesUnaccrued;
    mapping(address account => mapping(uint256 timestamp => Position position)) public positions;

    constructor(address newAsset, address newOwner, uint32 newEpochs) Ownable(newOwner) {
        asset = newAsset;
        unwindingEpochs = newEpochs;
        iusd = address(new TestnetIusdReceipt(address(this)));
        lockedToken = address(new TestnetInfiniFiLockedVault(iusd, newOwner, address(this), newEpochs));
    }

    /// @inheritdoc ITestnetInfiniFi
    function deposit(uint256 assets, address receiver) public returns (uint256 receipts) {
        if (assets == 0) revert InvalidAmount();
        receipts = assets.mulDiv(1e18, 10 ** IERC20Metadata(asset).decimals());
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        TestnetIusdReceipt(iusd).mint(receiver, receipts);
        emit Deposit(receiver, assets, receipts);
    }

    /// @inheritdoc ITestnetInfiniFi
    function deployCapital(address receiver, uint256 assets) public onlyOwner {
        if (assets == 0 || assets > IERC20(asset).balanceOf(address(this))) revert InvalidAmount();
        receivable += assets;
        IERC20(asset).safeTransfer(receiver, assets);
        emit DeployCapital(receiver, assets);
    }

    /// @inheritdoc ITestnetInfiniFi
    function repayCapital(uint256 assets) public {
        if (assets == 0 || assets > receivable) revert InvalidAmount();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        receivable -= assets;
        emit RepayCapital(msg.sender, assets);
    }

    /// @inheritdoc IInfiniFiGateway
    function startUnwinding(uint256 shares, uint32 epochs) public {
        if (lossesUnaccrued) revert LossesUnaccrued();
        if (epochs != unwindingEpochs || shares == 0) revert InvalidAmount();
        if (positions[msg.sender][block.timestamp].units > 0) revert InvalidRequest();
        IERC20(lockedToken).safeTransferFrom(msg.sender, address(this), shares);
        uint256 receipts = IERC4626(lockedToken).redeem(shares, address(this), address(this));
        // Native epochs align to whole weeks, and maturity is measured from the current epoch boundary.
        uint256 maturity = (block.timestamp / 1 weeks + epochs + 1) * 1 weeks;
        positions[msg.sender][block.timestamp] =
            Position({units: receipts.mulDiv(1e18, lossFactor), maturity: maturity});
        reservedReceipts += receipts;
        emit StartUnwinding(msg.sender, block.timestamp, receipts, maturity);
    }

    /// @inheritdoc IInfiniFiUnwindingModule
    function balanceOf(address account, uint256 timestamp) public view returns (uint256) {
        return positions[account][timestamp].units.mulDiv(lossFactor, 1e18);
    }

    /// @inheritdoc IInfiniFiGateway
    function withdraw(uint256 timestamp) public {
        if (lossesUnaccrued) revert LossesUnaccrued();
        Position memory position = positions[msg.sender][timestamp];
        if (position.units == 0) revert InvalidRequest();
        if (block.timestamp < position.maturity) revert NotMature();
        uint256 receipts = balanceOf(msg.sender, timestamp);
        delete positions[msg.sender][timestamp];
        reservedReceipts -= receipts;
        IERC20(iusd).safeTransfer(msg.sender, receipts);
        emit Withdraw(msg.sender, timestamp, receipts);
    }

    /// @inheritdoc IInfiniFiGateway
    function redeem(address receiver, uint256 amount, uint256 minAssetsOut) public returns (uint256 assetsOut) {
        if (lossesUnaccrued) revert LossesUnaccrued();
        if (amount == 0) revert InvalidAmount();
        assetsOut = amount.mulDiv(10 ** IERC20Metadata(asset).decimals(), 1e18);
        // Enqueuing would return below minAssetsOut in the native gateway. A full-value account minimum
        // therefore rejects the transaction atomically and keeps all iUSD available for a later retry.
        if (assetsOut < minAssetsOut || assetsOut > IERC20(asset).balanceOf(address(this))) revert InvalidAmount();
        IERC20(iusd).safeTransferFrom(msg.sender, address(this), amount);
        TestnetIusdReceipt(iusd).burn(amount);
        IERC20(asset).safeTransfer(receiver, assetsOut);
        emit Redeem(msg.sender, receiver, amount, assetsOut);
    }

    /// @inheritdoc ITestnetInfiniFi
    function reportLoss(uint256 newLossFactor) public onlyOwner {
        if (newLossFactor == 0 || newLossFactor >= lossFactor || lossesUnaccrued) revert InvalidAmount();
        uint256 newReserved = reservedReceipts.mulDiv(newLossFactor, lossFactor);
        uint256 lostReceipts = reservedReceipts - newReserved;
        uint256 lostAssets = lostReceipts.mulDiv(10 ** IERC20Metadata(asset).decimals(), 1e18);
        if (lostAssets == 0 || lostAssets > receivable) revert InvalidAmount();
        receivable -= lostAssets;
        reservedReceipts = newReserved;
        lossFactor = newLossFactor;
        lossesUnaccrued = true;
        TestnetIusdReceipt(iusd).burn(lostReceipts);
        emit ReportLoss(newLossFactor, lostAssets);
    }

    /// @inheritdoc ITestnetInfiniFi
    function accrueLoss() public onlyOwner {
        if (!lossesUnaccrued) revert InvalidRequest();
        lossesUnaccrued = false;
        emit AccrueLoss();
    }
}

/**
 *  @title ITestnetInfiniFiBucketFeed @notice Interface for explicitly published, funded liUSD NAV rounds.
 */
interface ITestnetInfiniFiBucketFeed {
    /**
     * @notice Raised when a requested Chainlink round does not exist.
     */
    error InvalidRound();
    /**
     * @notice Emitted when a new round snapshots funded liUSD NAV.
     */
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
    /**
     * @notice Emitted when a round publishes its answer and actual publication time.
     */
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    /**
     * @notice Emitted when the operator refreshes the feed from funded vault NAV.
     */
    event Refresh(uint80 indexed roundId);
    /**
     * @notice Returns the liUSD vault whose funded NAV is published.
     */
    function vault() external view returns (address);
    /**
     * @notice Returns the 18-decimal answer denomination.
     */
    function decimals() external view returns (uint8);
    /**
     * @notice Returns the latest explicitly published round ID.
     */
    function latestRound() external view returns (uint80);
    /**
     * @notice Returns this native Chainlink aggregator.
     */
    function aggregator() external view returns (address);
    /**
     * @notice Returns the latest stored answer and its actual publication timestamp.
     */
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    /**
     * @notice Returns a stored answer and its actual publication timestamp.
     */
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80);
    /**
     * @notice Returns a stored round's NAV and publication timestamp.
     */
    function rounds(uint80 roundId) external view returns (int256 answer, uint48 timestamp);
    /**
     * @notice Publishes current funded vault NAV as a new stored Chainlink round.
     */
    function refresh() external;
}

/// @title TestnetInfiniFiBucketFeed
/// @notice Native bucket feed with explicit operator NAV publication and real stored round freshness.
contract TestnetInfiniFiBucketFeed is Ownable, ITestnetInfiniFiBucketFeed {
    struct Round {
        int256 answer;
        uint48 timestamp;
    }
    address public immutable vault;
    uint8 public immutable decimals = 18;
    uint80 public latestRound;
    mapping(uint80 round => Round data) public rounds;

    constructor(address newVault, address newOwner) Ownable(newOwner) {
        vault = newVault;
        _refresh();
    }

    /// @inheritdoc ITestnetInfiniFiBucketFeed
    function aggregator() public view returns (address) {
        return address(this);
    }

    /// @inheritdoc ITestnetInfiniFiBucketFeed
    function refresh() public onlyOwner {
        _refresh();
    }

    /// @inheritdoc ITestnetInfiniFiBucketFeed
    function latestRoundData() public view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(latestRound);
    }

    /// @inheritdoc ITestnetInfiniFiBucketFeed
    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory round = rounds[roundId];
        if (round.timestamp == 0) revert InvalidRound();
        return (roundId, round.answer, round.timestamp, round.timestamp, roundId);
    }

    function _refresh() internal {
        uint256 price = IERC4626(vault).convertToAssets(1e18);
        ++latestRound;
        rounds[latestRound] = Round({answer: int256(price), timestamp: uint48(block.timestamp)});
        emit NewRound(latestRound, msg.sender, block.timestamp);
        emit AnswerUpdated(int256(price), latestRound, block.timestamp);
        emit Refresh(latestRound);
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
     * @notice Raised when a token profile is outside the supported eleven integrations.
     */
    error InvalidProfile();
    /**
     * @notice Deploys funded native protocol topology, its actual family oracle, and a configurable production account.
     * @dev Profiles: PRIME=0, AUTO=1, DUSD=2, sAID=3, USD3=4, sUSD3=5, sthUSD=6, sUSN=7,
     * liUSD4w=8, liUSD13w=9, AA_FalconX=10. Endpoint identifies the request/settlement entrypoint;
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
        if (profile > 10) revert InvalidProfile();
        if (broadcast) vm.startBroadcast(owner);
        else vm.startPrank(owner);
        if (profile < 2 || profile == 5) {
            address underlying = IERC4626(endpoint).asset();
            IERC20(underlying).approve(endpoint, assets);
            uint256 underlyingShares = IERC4626(endpoint).deposit(assets, owner);
            IERC20(endpoint).approve(token, underlyingShares);
            shares = IERC4626(token).deposit(underlyingShares, receiver);
        } else if (profile == 8 || profile == 9) {
            IERC20(TestnetInfiniFiGateway(endpoint).asset()).approve(endpoint, assets);
            uint256 receipts = TestnetInfiniFiGateway(endpoint).deposit(assets, owner);
            IERC20(TestnetInfiniFiGateway(endpoint).iusd()).approve(token, receipts);
            shares = IERC4626(token).deposit(receipts, receiver);
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
        if (profile > 10) revert InvalidProfile();
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
        } else if (profile == 2) {
            token = address(new TestnetMakinaMachine(asset, owner));
            endpoint = address(new TestnetMakinaRedeemer(token, owner));
            TestnetMakinaMachine(token).setRedeemer(endpoint);
            oracle =
                address(new MakinaOracle(515_533_500_000_000_000, 2_062_134_000_000_000_000, token, token, 48 hours));
            implementation = address(new MakinaAccount(oracle, factory, 72 minutes, endpoint, token, cow));
        } else if (profile == 3) {
            token = address(new TestnetSaid(asset, owner));
            endpoint = token;
            oracle = address(new SaidOracle(527_574_236_280_171_822, 2_110_296_945_120_687_290, token));
            implementation = address(new GaibAccount(oracle, factory, 6 days, token, cow));
        } else if (profile == 4) {
            token = address(new TestnetYieldVault(asset, owner, "Testnet ThreeJane USD3", "USD3", 18));
            endpoint = token;
            oracle = address(new ThreeJaneOracle(0.5e18, 2.5e18, token));
            implementation = address(new ThreeJaneAccount(oracle, factory, token, cow));
        } else if (profile == 5) {
            endpoint = address(new TestnetYieldVault(asset, owner, "Testnet ThreeJane USD3", "USD3", 18));
            token = address(new TestnetSUSD3(endpoint, owner));
            oracle = address(new SThreeJaneOracle(0.5e18, 2.5e18, token));
            implementation = address(new SThreeJaneAccount(oracle, factory, token, cow));
        } else if (profile == 6) {
            token = address(new TestnetTheoVault(asset, owner));
            endpoint = token;
            oracle = address(new ERC4626Oracle(0.5e18, 2.5e18, token));
            implementation = address(new TheoAccount(oracle, factory, token, cow));
        } else if (profile == 7) {
            endpoint = address(new TestnetNoonHandler(asset, owner));
            token = address(new TestnetNoonVault(asset, owner, endpoint));
            TestnetNoonHandler(endpoint).setVault(token);
            oracle = address(new NoonRateProviderOracle(0.5e18, 2.5e18, token, token));
            implementation = address(new NoonAccount(oracle, factory, 17 hours, token, endpoint, cow));
        } else if (profile < 10) {
            uint32 epochs = profile == 8 ? 4 : 13;
            endpoint = address(new TestnetInfiniFiGateway(asset, owner, epochs));
            token = TestnetInfiniFiGateway(endpoint).lockedToken();
            address feed = address(new TestnetInfiniFiBucketFeed(token, owner));
            oracle = address(
                new ChainlinkOracle(
                    profile == 8 ? 599_319_571_104_044_928 : 610_302_338_122_868_364,
                    profile == 8 ? 2_397_278_284_416_179_714 : 2_441_209_352_491_473_456,
                    [feed, address(0)],
                    [uint48(30 days), uint48(0)]
                )
            );
            implementation = address(
                new InfiniFiAccount(
                    oracle,
                    factory,
                    profile == 8 ? 3 days : 7 days,
                    token,
                    endpoint,
                    endpoint,
                    TestnetInfiniFiGateway(endpoint).iusd(),
                    epochs,
                    cow
                )
            );
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
