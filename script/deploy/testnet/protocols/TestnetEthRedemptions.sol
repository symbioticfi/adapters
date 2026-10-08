// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {EtherFiAccount} from "src/contracts/ll-adapter/EtherFiAccount.sol";
import {LidoAccount} from "src/contracts/ll-adapter/LidoAccount.sol";
import {WeETHOracle} from "src/contracts/ll-adapter/oracles/WeETHOracle.sol";
import {WstETHOracle} from "src/contracts/ll-adapter/oracles/WstETHOracle.sol";

import {IEtherFiLiquidityPool} from "src/interfaces/ll-adapter/etherfi/IEtherFiLiquidityPool.sol";
import {IEtherFiRedemptionManager} from "src/interfaces/ll-adapter/etherfi/IEtherFiRedemptionManager.sol";
import {IEtherFiWithdrawRequestNFT} from "src/interfaces/ll-adapter/etherfi/IEtherFiWithdrawRequestNFT.sol";
import {ILidoWithdrawalQueue} from "src/interfaces/ll-adapter/lido/ILidoWithdrawalQueue.sol";
import {IWETH} from "src/interfaces/ll-adapter/etherfi/IWETH.sol";
import {IWeETH} from "src/interfaces/ll-adapter/etherfi/IWeETH.sol";
import {IWstETH} from "src/interfaces/ll-adapter/lido/IWstETH.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Script} from "forge-std/Script.sol";

/**
 * @title TestnetWETH
 * @notice ETH-backed wrapped native token for the standalone testnet.
 * @dev Supply is created only by native deposits. No privileged mint exists.
 */
contract TestnetWETH is ERC20, ReentrancyGuard, IWETH {
    using Address for address payable;

    /* CONSTRUCTOR */

    constructor() ERC20("Wrapped Testnet Ether", "WETH") {}

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IWETH
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Burns WETH and releases its deposited ETH to the caller.
    function withdraw(uint256 amount) public nonReentrant {
        _burn(msg.sender, amount);
        payable(msg.sender).sendValue(amount);
    }

    /* RECEIVE FUNCTION */

    receive() external payable {
        deposit();
    }
}

/**
 * @title TestnetNativeStake
 * @notice Deposit-funded stETH/eETH denomination with an authorized redemption endpoint.
 * @dev The operator can move cash into explicitly tracked external staking custody. Returning that cash is required
 * before withdrawals can settle. External custody is an operator trust assumption, as on a permissioned testnet issuer.
 */
contract TestnetNativeStake is ERC20, Ownable, ReentrancyGuard {
    using Address for address payable;

    error InsufficientLiquidity();
    error InvalidAmount();
    error InvalidCaller();
    error InvalidReceiver();

    /* IMMUTABLES */

    address public immutable redemptionEndpoint;

    /* STATE VARIABLES */

    uint256 public deployedAssets;

    event Deposit(address indexed caller, address indexed receiver, uint256 amount);
    event DeployLiquidity(address indexed receiver, uint256 amount);
    event FundLiquidity(uint256 amount);
    event Release(address indexed receiver, uint256 amount);

    /* CONSTRUCTOR */

    constructor(address newOwner, address newRedemptionEndpoint, string memory newName, string memory newSymbol)
        ERC20(newName, newSymbol)
        Ownable(newOwner)
    {
        redemptionEndpoint = newRedemptionEndpoint;
    }

    /* PUBLIC FUNCTIONS */

    /// @notice Deposits ETH and issues an equal amount of liquid staking denomination to the receiver.
    function deposit(address receiver) public payable {
        if (receiver == address(0)) revert InvalidReceiver();
        if (msg.value == 0) revert InvalidAmount();
        _mint(receiver, msg.value);
        emit Deposit(msg.sender, receiver, msg.value);
    }

    /// @notice Moves liquid ETH to the operator's external staking custody, recording the amount owed back.
    function deployLiquidity(address receiver, uint256 amount) public nonReentrant onlyOwner {
        if (receiver == address(0)) revert InvalidReceiver();
        if (amount == 0) revert InvalidAmount();
        if (amount > address(this).balance) revert InsufficientLiquidity();
        deployedAssets += amount;
        emit DeployLiquidity(receiver, amount);
        payable(receiver).sendValue(amount);
    }

    /// @notice Returns native ETH from external staking custody without issuing additional tokens.
    function fundLiquidity() public payable {
        if (msg.value == 0 || msg.value > deployedAssets) revert InvalidAmount();
        deployedAssets -= msg.value;
        emit FundLiquidity(msg.value);
    }

    /// @notice Burns endpoint-held staking denomination and pays its native backing to the receiver.
    function release(address receiver, uint256 amount) public nonReentrant {
        if (redemptionEndpoint != msg.sender) revert InvalidCaller();
        if (receiver == address(0)) revert InvalidReceiver();
        if (amount == 0) revert InvalidAmount();
        if (amount > address(this).balance) revert InsufficientLiquidity();
        _burn(msg.sender, amount);
        emit Release(receiver, amount);
        payable(receiver).sendValue(amount);
    }
}

/**
 * @title TestnetWrappedStake
 * @notice Custodied staking denomination implementing both wstETH and weETH conversion ABIs.
 * @dev Donations of genuinely deposited underlying tokens increase the native rate. There is no rate setter or mint.
 */
contract TestnetWrappedStake is ERC20, IWstETH, IWeETH {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error InvalidAmount();

    /* IMMUTABLES */

    address public immutable underlying;

    /* CONSTRUCTOR */

    constructor(address newUnderlying, string memory newName, string memory newSymbol) ERC20(newName, newSymbol) {
        underlying = newUnderlying;
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc IWstETH
    function wrap(uint256 amount) public returns (uint256 shares) {
        shares = getWstETHByStETH(amount);
        if (shares == 0) revert InvalidAmount();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, shares);
    }

    /// @inheritdoc IWstETH
    function unwrap(uint256 shares) public override(IWstETH, IWeETH) returns (uint256 amount) {
        amount = getStETHByWstETH(shares);
        if (amount == 0) revert InvalidAmount();
        _burn(msg.sender, shares);
        IERC20(underlying).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IWstETH
    function getWstETHByStETH(uint256 amount) public view returns (uint256 shares) {
        uint256 supply = totalSupply();
        return supply == 0 ? amount : amount.mulDiv(supply, IERC20(underlying).balanceOf(address(this)));
    }

    /// @inheritdoc IWstETH
    function getStETHByWstETH(uint256 shares) public view returns (uint256 amount) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(IERC20(underlying).balanceOf(address(this)), supply);
    }

    /// @inheritdoc IWeETH
    function getEETHByWeETH(uint256 shares) public view returns (uint256 amount) {
        return getStETHByWstETH(shares);
    }
}

/**
 * @title TestnetLidoQueue
 * @notice Deposit-funded Lido request NFTs with delayed operator finalization and reserved native payouts.
 * @dev Validators, beacon proofs and rebasing stETH accounting are replaced by explicit operator custody and donations.
 */
contract TestnetLidoQueue is ERC721, Ownable, ReentrancyGuard, ILidoWithdrawalQueue {
    using Address for address payable;
    using SafeERC20 for IERC20;

    error InvalidAmount();
    error InvalidCaller();
    error InvalidCheckpoint();
    error InvalidRequest();
    error NotReady();

    /* IMMUTABLES */

    address public immutable stETH;
    address public immutable wstETH;
    uint48 public immutable settlementDelay;
    uint256 public immutable MIN_STETH_WITHDRAWAL_AMOUNT;
    uint256 public immutable MAX_STETH_WITHDRAWAL_AMOUNT;

    /* STATE VARIABLES */

    uint256 public nextRequestId = 1;
    uint256 public reservedAssets;
    uint256 public lastCheckpointIndex;
    mapping(uint256 requestId => WithdrawalRequestStatus status) internal _requests;
    mapping(uint256 requestId => uint256 amount) public payouts;
    mapping(uint256 requestId => uint256 checkpoint) public checkpoints;

    event RequestWithdrawals(uint256 indexed requestId, address indexed recipient, uint256 amount);
    event Finalize(uint256 indexed requestId, uint256 amount, uint256 checkpoint);
    event ClaimWithdrawal(uint256 indexed requestId, address indexed recipient, uint256 amount);

    /* CONSTRUCTOR */

    constructor(address newOwner, uint48 newSettlementDelay)
        ERC721("Testnet Lido withdrawal", "unstETH")
        Ownable(newOwner)
    {
        settlementDelay = newSettlementDelay;
        MIN_STETH_WITHDRAWAL_AMOUNT = 100;
        MAX_STETH_WITHDRAWAL_AMOUNT = 1000 ether;
        stETH = address(new TestnetNativeStake(newOwner, address(this), "Testnet staked Ether", "stETH"));
        wstETH = address(new TestnetWrappedStake(stETH, "Testnet wrapped staked Ether", "wstETH"));
    }

    /* PUBLIC FUNCTIONS */

    /// @inheritdoc ILidoWithdrawalQueue
    function requestWithdrawals(uint256[] calldata amounts, address recipient)
        public
        nonReentrant
        returns (uint256[] memory requestIds)
    {
        requestIds = new uint256[](amounts.length);
        for (uint256 i; i < amounts.length; ++i) {
            IERC20(stETH).safeTransferFrom(msg.sender, address(this), amounts[i]);
            requestIds[i] = _request(amounts[i], amounts[i], recipient);
        }
    }

    /// @inheritdoc ILidoWithdrawalQueue
    function requestWithdrawalsWstETH(uint256[] calldata amounts, address recipient)
        public
        nonReentrant
        returns (uint256[] memory requestIds)
    {
        requestIds = new uint256[](amounts.length);
        for (uint256 i; i < amounts.length; ++i) {
            IERC20(wstETH).safeTransferFrom(msg.sender, address(this), amounts[i]);
            requestIds[i] = _request(IWstETH(wstETH).unwrap(amounts[i]), amounts[i], recipient);
        }
    }

    /// @notice Finalizes a mature request, burns its custodied stETH and reserves a payout bounded by its entitlement.
    function finalize(uint256 requestId, uint256 amount) public nonReentrant onlyOwner {
        WithdrawalRequestStatus storage request = _requests[requestId];
        if (request.owner == address(0) || request.isFinalized || request.isClaimed) revert InvalidRequest();
        if (block.timestamp < request.timestamp + settlementDelay) revert NotReady();
        if (amount == 0 || amount > request.amountOfStETH) revert InvalidAmount();
        TestnetNativeStake(stETH).release(address(this), request.amountOfStETH);
        request.isFinalized = true;
        payouts[requestId] = amount;
        reservedAssets += amount;
        checkpoints[requestId] = ++lastCheckpointIndex;
        emit Finalize(requestId, amount, lastCheckpointIndex);
    }

    /// @inheritdoc ILidoWithdrawalQueue
    function claimWithdrawal(uint256 requestId) public nonReentrant {
        WithdrawalRequestStatus storage request = _requests[requestId];
        if (!request.isFinalized || request.isClaimed) revert NotReady();
        if (ownerOf(requestId) != msg.sender) revert InvalidCaller();
        uint256 amount = payouts[requestId];
        request.isClaimed = true;
        reservedAssets -= amount;
        _burn(requestId);
        emit ClaimWithdrawal(requestId, msg.sender, amount);
        payable(msg.sender).sendValue(amount);
    }

    /// @inheritdoc ILidoWithdrawalQueue
    function getWithdrawalStatus(uint256[] calldata requestIds)
        public
        view
        returns (WithdrawalRequestStatus[] memory statuses)
    {
        statuses = new WithdrawalRequestStatus[](requestIds.length);
        for (uint256 i; i < requestIds.length; ++i) {
            statuses[i] = _requests[requestIds[i]];
            if (!statuses[i].isClaimed && statuses[i].owner != address(0)) {
                statuses[i].owner = ownerOf(requestIds[i]);
            }
        }
    }

    /// @inheritdoc ILidoWithdrawalQueue
    function getLastCheckpointIndex() public view returns (uint256) {
        return lastCheckpointIndex;
    }

    /// @inheritdoc ILidoWithdrawalQueue
    function findCheckpointHints(uint256[] calldata requestIds, uint256 firstIndex, uint256 lastIndex)
        public
        view
        returns (uint256[] memory hints)
    {
        if (firstIndex == 0 || lastIndex < firstIndex || lastIndex > lastCheckpointIndex) {
            revert InvalidCheckpoint();
        }
        hints = new uint256[](requestIds.length);
        for (uint256 i; i < requestIds.length; ++i) {
            if (i > 0 && requestIds[i] <= requestIds[i - 1]) revert InvalidRequest();
            hints[i] = checkpoints[requestIds[i]];
            if (hints[i] < firstIndex || hints[i] > lastIndex) revert InvalidCheckpoint();
        }
    }

    /// @inheritdoc ILidoWithdrawalQueue
    function getClaimableEther(uint256[] calldata requestIds, uint256[] calldata hints)
        public
        view
        returns (uint256[] memory amounts)
    {
        if (requestIds.length != hints.length) revert InvalidCheckpoint();
        amounts = new uint256[](requestIds.length);
        for (uint256 i; i < requestIds.length; ++i) {
            if (hints[i] == 0 || hints[i] != checkpoints[requestIds[i]]) revert InvalidCheckpoint();
            if (!_requests[requestIds[i]].isClaimed) amounts[i] = payouts[requestIds[i]];
        }
    }

    /* INTERNAL FUNCTIONS */

    function _request(uint256 amount, uint256 shares, address recipient) internal returns (uint256 requestId) {
        if (amount < MIN_STETH_WITHDRAWAL_AMOUNT || amount > MAX_STETH_WITHDRAWAL_AMOUNT) revert InvalidAmount();
        requestId = nextRequestId++;
        _requests[requestId] = WithdrawalRequestStatus({
            amountOfStETH: amount,
            amountOfShares: shares,
            owner: recipient,
            timestamp: block.timestamp,
            isFinalized: false,
            isClaimed: false
        });
        _mint(recipient, requestId);
        emit RequestWithdrawals(requestId, recipient, amount);
    }

    /* RECEIVE FUNCTION */

    receive() external payable {}
}

/**
 * @title TestnetEtherFiPool
 * @notice Ether.fi liquidity pool and withdrawal NFT with backed queued and instant native redemptions.
 * @dev The pool and NFT share one address; validator proofs are replaced by mature, owner-approved finalization.
 */
contract TestnetEtherFiPool is ERC721, Ownable, ReentrancyGuard, IEtherFiLiquidityPool, IEtherFiWithdrawRequestNFT {
    using SafeERC20 for IERC20;
    using Address for address payable;

    error InvalidAmount();
    error InvalidCaller();
    error InvalidRequest();
    error NotReady();

    /* IMMUTABLES */

    address public immutable eETH;
    address public immutable weETH;
    address public immutable redemptionManager;
    uint48 public immutable settlementDelay;

    /* STATE VARIABLES */

    uint256 public nextRequestId = 1;
    uint256 public reservedAssets;
    uint32 public withdrawalFeeGwei;
    mapping(uint256 requestId => WithdrawRequest request) internal _requests;
    mapping(uint256 requestId => uint48 timestamp) public requestedAt;
    mapping(uint256 requestId => bool status) public finalized;

    event RequestWithdraw(uint256 indexed requestId, address indexed recipient, uint256 amount, uint32 feeGwei);
    event SetWithdrawalFee(uint32 feeGwei);
    event Finalize(uint256 indexed requestId, uint256 payout);
    event ClaimWithdraw(uint256 indexed requestId, address indexed recipient, uint256 amount);
    event RedeemInstant(address indexed receiver, uint256 amount, uint256 fee);

    /* CONSTRUCTOR */

    constructor(address newOwner, uint48 newSettlementDelay)
        ERC721("Testnet ether.fi withdrawal", "ether.fi unstake")
        Ownable(newOwner)
    {
        settlementDelay = newSettlementDelay;
        eETH = address(new TestnetNativeStake(newOwner, address(this), "Testnet ether.fi staked Ether", "eETH"));
        weETH = address(new TestnetWrappedStake(eETH, "Testnet ether.fi wrapped Ether", "weETH"));
        redemptionManager = address(new TestnetEtherFiRedemptionManager(newOwner, address(this), weETH));
    }

    /* PUBLIC FUNCTIONS */

    /// @notice Returns the withdraw-request NFT endpoint used by the production account.
    function withdrawalRequestNFT() public view returns (address) {
        return address(this);
    }

    /// @notice Sets the native queued-withdrawal fee for subsequent requests.
    function setWithdrawalFee(uint32 newFeeGwei) public onlyOwner {
        withdrawalFeeGwei = newFeeGwei;
        emit SetWithdrawalFee(newFeeGwei);
    }

    /// @inheritdoc IEtherFiLiquidityPool
    function requestWithdraw(address recipient, uint256 amount) public nonReentrant returns (uint256 requestId) {
        if (amount > type(uint96).max || amount <= uint256(withdrawalFeeGwei) * 1 gwei) revert InvalidAmount();
        IERC20(eETH).safeTransferFrom(msg.sender, address(this), amount);
        requestId = nextRequestId++;
        _requests[requestId] = WithdrawRequest({
            amountOfEEth: uint96(amount), shareOfEEth: uint96(amount), isValid: true, feeGwei: withdrawalFeeGwei
        });
        requestedAt[requestId] = uint48(block.timestamp);
        _safeMint(recipient, requestId);
        emit RequestWithdraw(requestId, recipient, amount, withdrawalFeeGwei);
    }

    /// @notice Finalizes a mature withdrawal, burning its custodied eETH and reserving its net native payout.
    function finalize(uint256 requestId) public nonReentrant onlyOwner {
        WithdrawRequest storage request = _requests[requestId];
        if (!request.isValid || finalized[requestId]) revert InvalidRequest();
        if (block.timestamp < uint256(requestedAt[requestId]) + settlementDelay) revert NotReady();
        TestnetNativeStake(eETH).release(address(this), request.amountOfEEth);
        finalized[requestId] = true;
        uint256 payout = uint256(request.amountOfEEth) - uint256(request.feeGwei) * 1 gwei;
        reservedAssets += payout;
        emit Finalize(requestId, payout);
    }

    /// @inheritdoc IEtherFiWithdrawRequestNFT
    function claimWithdraw(uint256 requestId) public nonReentrant {
        WithdrawRequest storage request = _requests[requestId];
        if (!request.isValid || !finalized[requestId]) revert NotReady();
        if (ownerOf(requestId) != msg.sender) revert InvalidCaller();
        uint256 amount = uint256(request.amountOfEEth) - uint256(request.feeGwei) * 1 gwei;
        request.isValid = false;
        reservedAssets -= amount;
        _burn(requestId);
        emit ClaimWithdraw(requestId, msg.sender, amount);
        payable(msg.sender).sendValue(amount);
    }

    /// @notice Burns manager-transferred eETH against funded liquidity and pays the net native amount.
    function redeemInstant(uint256 amount, address receiver, uint16 feeBps) public nonReentrant {
        if (redemptionManager != msg.sender) revert InvalidCaller();
        if (feeBps > 10_000) revert InvalidAmount();
        IERC20(eETH).safeTransferFrom(msg.sender, address(this), amount);
        TestnetNativeStake(eETH).release(address(this), amount);
        uint256 fee = amount * feeBps / 10_000;
        emit RedeemInstant(receiver, amount, fee);
        payable(receiver).sendValue(amount - fee);
    }

    /// @inheritdoc IEtherFiLiquidityPool
    function amountForShare(uint256 share) public pure returns (uint256) {
        return share;
    }

    /// @inheritdoc IEtherFiWithdrawRequestNFT
    function getRequest(uint256 requestId) public view returns (WithdrawRequest memory) {
        return _requests[requestId];
    }

    /* RECEIVE FUNCTION */

    receive() external payable {}
}

/**
 * @title TestnetEtherFiRedemptionManager
 * @notice ETH-only instant redemption with a funded-cash check, configurable fee and replenishing gwei bucket.
 */
contract TestnetEtherFiRedemptionManager is Ownable, ReentrancyGuard, IEtherFiRedemptionManager {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error InvalidAmount();
    error InvalidReceiver();
    error RedemptionUnavailable();

    /* IMMUTABLES */

    address public immutable pool;
    address public immutable weETH;
    address public immutable ETH_ADDRESS;

    /* STATE VARIABLES */

    bool public enabled;
    uint16 public exitFeeBps;
    BucketLimit public bucket;

    event Configure(bool enabled, uint16 feeBps, uint64 capacityGwei, uint64 refillGweiPerSecond);
    event RedeemWeEth(address indexed caller, address indexed receiver, uint256 shares, uint256 nativeAmount);

    /* CONSTRUCTOR */

    constructor(address newOwner, address newPool, address newWeETH) Ownable(newOwner) {
        pool = newPool;
        weETH = newWeETH;
        ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }

    /* PUBLIC FUNCTIONS */

    /// @notice Configures instant redemption and resets a bucket denominated in gwei.
    function configure(bool newEnabled, uint16 newFeeBps, uint64 newCapacityGwei, uint64 newRefillGweiPerSecond)
        public
        onlyOwner
    {
        if (newFeeBps > 10_000) revert InvalidAmount();
        enabled = newEnabled;
        exitFeeBps = newFeeBps;
        bucket = BucketLimit({
            capacity: newCapacityGwei,
            remaining: newCapacityGwei,
            lastRefill: uint64(block.timestamp),
            refillRate: newRefillGweiPerSecond
        });
        emit Configure(newEnabled, newFeeBps, newCapacityGwei, newRefillGweiPerSecond);
    }

    /// @inheritdoc IEtherFiRedemptionManager
    function canRedeem(uint256 amount, address token) public view returns (bool) {
        return enabled && token == ETH_ADDRESS && amount > 0 && amount.ceilDiv(1 gwei) <= _remaining()
            && amount <= TestnetEtherFiPool(payable(pool)).eETH().balance;
    }

    /// @inheritdoc IEtherFiRedemptionManager
    function redeemWeEth(uint256 shares, address receiver, address outputToken) public nonReentrant {
        if (receiver == address(0)) revert InvalidReceiver();
        uint256 amount = IWeETH(weETH).getEETHByWeETH(shares);
        if (!canRedeem(amount, outputToken)) revert RedemptionUnavailable();
        bucket.remaining = uint64(_remaining() - amount.ceilDiv(1 gwei));
        bucket.lastRefill = uint64(block.timestamp);
        IERC20(weETH).safeTransferFrom(msg.sender, address(this), shares);
        amount = IWeETH(weETH).unwrap(shares);
        IERC20(TestnetEtherFiPool(payable(pool)).eETH()).forceApprove(pool, amount);
        TestnetEtherFiPool(payable(pool)).redeemInstant(amount, receiver, exitFeeBps);
        emit RedeemWeEth(msg.sender, receiver, shares, amount);
    }

    /// @inheritdoc IEtherFiRedemptionManager
    function tokenToRedemptionInfo(address token)
        public
        view
        returns (BucketLimit memory limit, uint16, uint16, uint16)
    {
        if (token != ETH_ADDRESS) return (limit, 0, 0, 0);
        limit = bucket;
        limit.remaining = uint64(_remaining());
        return (limit, 0, exitFeeBps, 0);
    }

    /* INTERNAL FUNCTIONS */

    function _remaining() internal view returns (uint256) {
        return Math.min(
            bucket.capacity, uint256(bucket.remaining) + (block.timestamp - bucket.lastRefill) * bucket.refillRate
        );
    }
}

/// @title TestnetEtherFiAccount
/// @notice Production EtherFiAccount implementation configured with standalone protocol addresses.
contract TestnetEtherFiAccount is EtherFiAccount {
    constructor(address newPool, address newWeth, address newOracle, address newFactory, address newCow)
        EtherFiAccount(
            TestnetEtherFiPool(payable(newPool)).eETH(),
            newWeth,
            newOracle,
            newFactory,
            newPool,
            TestnetEtherFiPool(payable(newPool)).weETH(),
            TestnetEtherFiPool(payable(newPool)).redemptionManager(),
            newCow,
            newPool
        )
    {}
}

/// @title TestnetEthDeploymentScript
/// @notice Deploys backed ETH protocol models and production account/oracle implementations under the selected owner.
contract TestnetEthDeploymentScript is Script {
    address internal immutable _OWNER;
    bool internal immutable _BROADCAST;

    constructor(address newOwner, bool broadcast) {
        _OWNER = newOwner;
        _BROADCAST = broadcast;
    }

    function deploy(address factory, address cow, address weth, bool etherfi)
        public
        returns (address token, address oracle, address endpoint, address implementation)
    {
        if (_BROADCAST) vm.startBroadcast(_OWNER);
        else vm.startPrank(_OWNER, _OWNER);
        if (etherfi) {
            endpoint = address(new TestnetEtherFiPool(_OWNER, 1 days));
            token = TestnetEtherFiPool(payable(endpoint)).weETH();
            oracle = address(new WeETHOracle(0.5e18, 2.5e18, token));
            implementation = address(new TestnetEtherFiAccount(endpoint, weth, oracle, factory, cow));
        } else {
            endpoint = address(new TestnetLidoQueue(_OWNER, 1 days));
            token = TestnetLidoQueue(payable(endpoint)).wstETH();
            oracle = address(new WstETHOracle(0.5e18, 2.5e18, token));
            implementation = address(
                new LidoAccount(
                    TestnetLidoQueue(payable(endpoint)).stETH(), weth, oracle, token, factory, endpoint, cow
                )
            );
        }
        if (_BROADCAST) vm.stopBroadcast();
        else vm.stopPrank();
    }
}
