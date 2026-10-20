// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Maximum complete owner-ledger scope accepted by the stateless selector.
 */
uint256 constant MAX_CLAIM_SCAN = 4096;

/**
 * @title IClaimReadiness
 * @notice Bounded native owner-ledger selection for claim recipes.
 */
interface IClaimReadiness {
    /* ERRORS */

    /**
     * @notice The complete ledger exceeds the supported scan scope.
     */
    error ScanLimit();

    /* FUNCTIONS */

    /**
     * @notice Selects the first matured, unclaimed Noon owner request.
     * @dev Reverts if the full request count exceeds MAX_CLAIM_SCAN. A zero id
     * is valid; callers must use amount as the independent execution gate.
     * Re-read after a claim to select the next eligible request.
     */
    function nextNoon(address handler, address account) external view returns (uint256 id, uint256 amount);

    /**
     * @notice Returns one Noon request's complete matured amount, or zero when pending or claimed.
     * @dev Use this getter bound to the selected id for pre/post claim readiness.
     */
    function noonReady(address handler, address account, uint256 id) external view returns (uint256 amount);

    /**
     * @notice Selects the first completed Pareto deposit or withdrawal epoch.
     * @dev Entitlement is the whole owner ledger amount, in underlying units
     * for deposits or tranche units for withdrawals. It is not an output quote.
     * The scope includes epoch zero through the strategy's next epoch and must
     * fit MAX_CLAIM_SCAN. A zero epoch is valid independently of entitlement.
     */
    function nextPareto(address queue, address account, bool deposit)
        external
        view
        returns (uint256 epoch, uint256 entitlement);

    /**
     * @notice Returns one completed Pareto epoch's whole owner entitlement, or zero while pending or empty.
     */
    function paretoEpochReady(address queue, address account, bool deposit, uint256 epoch)
        external
        view
        returns (uint256 entitlement);

    /**
     * @notice Returns a complete payable direct Pareto withdrawal entitlement, or zero while pending.
     * @dev Includes normal APR0 settlement and requires enough receipt cash for
     * the entire claim. It does not select a partial payment.
     */
    function paretoReady(address cdo, address account, bool instant) external view returns (uint256 amount);

    /**
     * @notice Returns the full converted 3F owner payout when withdrawals are enabled.
     * @dev Zero-value positions are idle. A separate fixed-target burn permission is required for each request.
     */
    function threeFReady(address request, address account) external view returns (uint256 amount);

    /**
     * @notice Selects the first complete, live 3F mint authorization within the configured request scope.
     * @dev The policy supplies the canonical factory, budget and minimum yield.
     * first is an explicit inventory baseline; every subsequent factory request
     * must fit maxScan (1..512), otherwise selection reverts. The guarded mint
     * must still verify factory, facility intent, collateral and exact deltas.
     */
    function nextThreeF(
        address policy,
        address account,
        address asset,
        address underlying,
        uint32 first,
        uint32 maxScan,
        uint256 maxPrincipal
    ) external view returns (address request, uint256 principal, uint256 yieldAssets);
}
