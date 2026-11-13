// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SzrEconomics } from "./SzrEconomics.sol";
import { Szr } from "./Szr.sol";
import { ContinuousAuction } from "./ContinuousAuction.sol";
import { ReleaseSchedule } from "./ReleaseSchedule.sol";
import { ISzrLiquidity, ISzrFeeCollector, ISzrMigration } from "./interfaces/ISzrModules.sol";

/// @notice SZR inventory, exact-NAV backing, redemption and collateral-backed reserve loans.
/// @dev Reserve cash and lent principal are separate. Team fees never count as token backing.
contract SzrCore is ReentrancyGuard {
    using ReleaseSchedule for ReleaseSchedule.State;
    uint256 public constant WAD = 1e18;
    uint256 public constant INACTIVITY_SECONDS = 90 days;
    uint256 public constant RELEASE_PER_DAY = 1_000_000e18;
    uint256 public constant MIN_RELEASE_PER_DAY = 100_000e18;
    uint256 public constant RELEASE_HALF_LIFE = 365 days;

    struct AuctionConfig {
        uint256 openingWad;
        uint256 floorWad;
        uint256 buffer;
    }

    struct Loan {
        uint256 collateral;
        uint256 principal;
        uint256 expiresAt;
    }

    Szr public immutable token;
    SzrEconomics public immutable economics;
    address public immutable backingAsset;
    address public immutable initializer;
    address public liquidity;
    address public feeJar;
    address public migration;
    uint256 public initialLiquidityTarget;
    bool public initialLiquidityReleased;
    uint256 public migrationAllocation;
    uint256 public migrationRemaining;
    bool public initialized;
    bool public launched;
    uint256 public startedAt;
    /// @notice Zero until migration ends; the sale, release schedule and fee auctions start then.
    uint256 public auctionsOpenAt;

    uint256 public unreleasedSupply;
    uint256 public reserveCash;
    uint256 public loanPrincipal;
    uint256 public pledgedSupply;
    uint256 public totalReclaimable;
    mapping(address owner => uint256 amount) public reclaimableCollateral;
    uint256 public totalReleased;
    ReleaseSchedule.State internal releaseBucket;
    ContinuousAuction.State internal saleCurve;
    uint256 public immutable saleBuffer;
    uint256 public saleUpdatedAt;
    uint256 public emptyBackingNumerator;
    uint256 public emptySupplyDenominator;

    mapping(address account => Loan) public loans;

    error ZeroAddress();
    error ZeroAmount();
    error NotInitializer();
    error NotManager();
    error InitialLiquidityAlreadyReleased();
    error InitialLiquidityNotReleased();
    error AlreadyInitialized();
    error NotInitialized();
    error NotLaunched();
    error AlreadyLaunched();
    error AuctionNotOpen();
    error InvalidModule();
    error InvalidBackingAsset();
    error InvalidBootstrapNAV();
    error NotLiquidity();
    error NotFeeJar();
    error NotMigration();
    error MigrationAlreadyConfigured();
    error MigrationOpen();
    error MigrationNotOpen();
    error TransferAmountMismatch();
    error InsufficientInventory();
    error ReleaseLimit();
    error AboveMaximum();
    error BelowMinimum();
    error AboveNAV();
    error InsufficientCash();
    error NoLoan();
    error LoanExpired();
    error NotExpired();
    error AbovePrincipal();
    error InsufficientReclaimable();
    error UncoveredLoan();
    error DeadlinePassed();
    error AccountingMismatch();
    error NoActiveSupply();

    event MigrationClosed(uint256 unusedAllocation);
    event InitialLiquidityReleased(uint256 tokens);
    event MigrationExtended(uint256 tokens);
    event MigrationConfigured(
        address indexed migration, uint256 allocation, uint256 liquidityTarget
    );
    event MigrationReleased(address indexed owner, uint256 tokens, uint256 backing);
    event Launched(uint256 startedAt);
    event Released(address indexed payer, uint256 tokens, uint256 backing);
    event AuctionPurchased(
        address indexed buyer, uint256 tokens, uint256 payment, uint256 backing, uint256 funding
    );
    event BackingDonated(address indexed payer, uint256 amount);
    event Redeemed(address indexed owner, uint256 tokens, uint256 backing);
    event InventoryRecycled(uint256 tokens);
    event SzrDonated(address indexed donor, uint256 tokens);
    event FeesAllocated(uint256 amount, uint256 reserves, uint256 team);
    event Initialized(address indexed liquidity, address indexed feeCollector);
    event Borrowed(
        address indexed owner, uint256 collateralAdded, uint256 principalAdded, uint256 fee
    );
    event Repaid(address indexed owner, uint256 principal, uint256 collateralReleased);
    event CollateralReclaimed(address indexed owner, uint256 amount);
    event Poked(address indexed owner, uint256 expiresAt);
    event LoanSettled(
        address indexed owner, uint256 principal, uint256 recycled, uint256 returned
    );

    modifier live() {
        if (!initialized) revert NotInitialized();
        if (!launched) revert NotLaunched();
        _;
    }

    constructor(
        address asset,
        uint256 bootstrapNAV,
        address teamBeneficiary,
        AuctionConfig memory sale
    ) {
        if (asset == address(0)) revert ZeroAddress();
        if (asset.code.length == 0) revert InvalidBackingAsset();
        if (ERC20(asset).decimals() != 18) revert InvalidBackingAsset();
        if (bootstrapNAV == 0) revert InvalidBootstrapNAV();
        if (bootstrapNAV > 1e24) revert InvalidBootstrapNAV();
        backingAsset = asset;
        initializer = msg.sender;
        economics = new SzrEconomics(asset, teamBeneficiary);
        token = new Szr("Sazare", "SZR");
        unreleasedSupply = token.totalSupply();
        emptyBackingNumerator = bootstrapNAV;
        emptySupplyDenominator = WAD;
        saleBuffer = sale.buffer;
        saleCurve = ContinuousAuction.create(sale.buffer, sale.openingWad, sale.floorWad);
        _checkSaleDepth(saleCurve);
    }

    /// @notice Binds the reserve ledger to fixed custody and fee modules exactly once.
    function initialize(address liquidityModule, address feeModule) external {
        if (msg.sender != initializer) revert NotInitializer();
        if (initialized) revert AlreadyInitialized();
        if (liquidityModule.code.length == 0) revert InvalidModule();
        if (feeModule.code.length == 0) revert InvalidModule();
        if (ISzrLiquidity(liquidityModule).core() != address(this)) revert InvalidModule();
        if (ISzrLiquidity(liquidityModule).feeJar() != feeModule) revert InvalidModule();
        if (ISzrFeeCollector(feeModule).core() != address(this)) revert InvalidModule();
        liquidity = liquidityModule;
        feeJar = feeModule;
        initialized = true;
        emit Initialized(liquidityModule, feeModule);
    }

    /// @notice Reserves full 1:1 migration and records the genesis liquidity allocation, which
    /// is taken from public inventory, never from the migration reservation.
    function configureMigration(address module, uint256 allocation, uint256 liquidityTokens)
        external
    {
        if (msg.sender != initializer) revert NotInitializer();
        if (launched) revert AlreadyLaunched();
        if (migration != address(0)) revert MigrationAlreadyConfigured();
        if (module.code.length == 0) revert InvalidModule();
        if (ISzrMigration(module).core() != address(this)) revert InvalidModule();
        if (allocation == 0) revert ZeroAmount();
        if (allocation > unreleasedSupply) revert InsufficientInventory();
        if (liquidityTokens > unreleasedSupply - allocation) revert InsufficientInventory();
        migration = module;
        initialLiquidityTarget = liquidityTokens;
        migrationAllocation = allocation;
        migrationRemaining = migrationAllocation;
        emit MigrationConfigured(module, migrationAllocation, liquidityTokens);
    }

    /// @notice Hands the fixed genesis allocation from public inventory to Liquidity, once.
    /// @dev These tokens become active claims with no backing, so NAV falls. That is only
    /// allowed while migration is open: no sale or loan exists yet to be diluted. They are not
    /// a scheduled release, so they consume no sale allowance.
    function releaseInitialLiquidity() external nonReentrant live returns (uint256 amount) {
        if (msg.sender != liquidity) revert NotLiquidity();
        if (migrationRemaining == 0) revert MigrationNotOpen();
        if (initialLiquidityReleased) revert InitialLiquidityAlreadyReleased();
        amount = initialLiquidityTarget;
        if (amount == 0) revert ZeroAmount();
        _checkpointSale();
        initialLiquidityReleased = true;
        unreleasedSupply -= amount;
        SafeTransferLib.safeTransfer(address(token), msg.sender, amount);
        emit InitialLiquidityReleased(amount);
    }

    /// @notice Ends migration permanently; unused reserved tokens join the scheduled public sale.
    /// @dev Closing starts the sale, the release clock and the fee auctions. Only the current
    /// Liquidity manager may close; the deployer keeps no authority once that role moves on.
    function closeMigration() external nonReentrant live {
        if (msg.sender != ISzrLiquidity(liquidity).manager()) revert NotManager();
        uint256 unused = migrationRemaining;
        if (unused == 0) revert MigrationNotOpen();
        _requireGenesisFunded();
        _checkpointSale();
        migrationRemaining = 0;
        _openAuctions();
        emit MigrationClosed(unused);
    }

    /// @notice Reserves more public inventory for migration while it is open.
    /// @dev Migration never ends by filling up. If the allowance is ever used up, by holders
    /// or by someone holding migrated tokens to keep others out, the manager can make room.
    function extendMigration(uint256 amount) external nonReentrant live {
        if (msg.sender != ISzrLiquidity(liquidity).manager()) revert NotManager();
        if (migrationRemaining == 0) revert MigrationNotOpen();
        // Until genesis is funded, public inventory still holds its allocation.
        _requireGenesisFunded();
        if (amount == 0) revert ZeroAmount();
        if (amount > publicInventory()) revert InsufficientInventory();
        _checkpointSale();
        migrationAllocation += amount;
        migrationRemaining += amount;
        emit MigrationExtended(amount);
    }

    /// @notice Receives actual legacy proceeds and releases reserved tokens without a NAV minimum.
    /// @dev Migration can lower NAV. Public auction issuance retains its backing requirement.
    /// The last unit of the allowance is never released, so migration cannot end by filling
    /// up: only the manager's `closeMigration` ends it.
    function releaseMigration(address owner, uint256 amount, uint256 backing)
        external
        nonReentrant
        live
    {
        if (msg.sender != migration) revert NotMigration();
        if (owner == address(0)) revert ZeroAddress();
        if (owner == address(this)) revert InvalidModule();
        if (amount == 0) revert ZeroAmount();
        if (amount >= migrationRemaining) revert InsufficientInventory();
        _receiveBacking(msg.sender, backing);
        reserveCash += backing;
        migrationRemaining -= amount;
        unreleasedSupply -= amount;
        SafeTransferLib.safeTransfer(address(token), owner, amount);
        emit MigrationReleased(owner, amount, backing);
    }

    /// @notice Starts migration without activating a separate LP allocation.
    /// @dev The sale clock starts only when migration ends, or here if none was configured.
    function launch() external nonReentrant {
        if (msg.sender != initializer) revert NotInitializer();
        if (!initialized) revert NotInitialized();
        if (launched) revert AlreadyLaunched();
        launched = true;
        startedAt = block.timestamp;
        if (migrationRemaining == 0) _openAuctions();
        ISzrLiquidity(liquidity).onLaunch();
        emit Launched(startedAt);
    }

    /// @dev Migration may not end while the genesis allocation is still in inventory. It could
    /// never be released afterwards, and its permanent pool tokens are what stop active supply
    /// shrinking to dust, where a few wei could set NAV to any value and price the sale out.
    function _requireGenesisFunded() internal view {
        if (initialLiquidityTarget == 0) return;
        if (!initialLiquidityReleased) revert InitialLiquidityNotReleased();
    }

    function _openAuctions() internal {
        auctionsOpenAt = block.timestamp;
        releaseBucket.updatedAt = block.timestamp;
        saleUpdatedAt = block.timestamp;
    }

    /// @notice Active claims include tokens held by the one-sided genesis position or any
    /// other pool.
    /// @dev Pool composition does not change active supply; only issuance and retirement do.
    function activeSupply() public view returns (uint256) {
        return token.totalSupply() - unreleasedSupply;
    }

    /// @notice Core cash and collateral-backed loan principal. Pool reserves are trading
    /// depth, not backing.
    /// @dev WETH in the one-sided genesis position is excluded because swaps can remove it.
    function backingAmount() public view returns (uint256) {
        return reserveCash + loanPrincipal;
    }

    function NAV() external view returns (uint256) {
        uint256 supply = activeSupply();
        if (supply == 0) {
            return
                FixedPointMathLib.fullMulDiv(emptyBackingNumerator, WAD, emptySupplyDenominator);
        }
        return FixedPointMathLib.fullMulDiv(backingAmount(), WAD, supply);
    }

    function backingRequired(uint256 tokens) public view returns (uint256) {
        uint256 supply = activeSupply();
        if (supply == 0) {
            return FixedPointMathLib.fullMulDivUp(
                tokens, emptyBackingNumerator, emptySupplyDenominator
            );
        }
        return FixedPointMathLib.fullMulDivUp(tokens, backingAmount(), supply);
    }

    /// @notice Unreserved inactive inventory is available to the shared public sale schedule.
    function publicInventory() public view returns (uint256) {
        return unreleasedSupply - migrationRemaining;
    }

    function releaseCredit() public view returns (uint256) {
        return
            ReleaseSchedule.projected(releaseBucket, auctionsOpenAt, block.timestamp) / 1 days;
    }

    function releaseReadyAt() external view returns (uint256) {
        return ReleaseSchedule.readyAt(releaseBucket, auctionsOpenAt);
    }

    function releaseDecayStartsAt() external view returns (uint256) {
        return ReleaseSchedule.decayStartsAt(releaseBucket, auctionsOpenAt);
    }

    function releaseState() external view returns (ReleaseSchedule.State memory) {
        return releaseBucket;
    }

    function availableRelease() public view returns (uint256) {
        uint256 credit = releaseCredit();
        uint256 inventory = publicInventory();
        return credit < inventory ? credit : inventory;
    }

    /// @notice Single continuous SZR/WETH sale, never priced below 1.5x NAV.
    /// @dev Reserve claims are funded before treasury WETH.
    function buy(uint256 amount, uint256 maximumPayment, uint256 deadline)
        external
        nonReentrant
        live
        returns (uint256 payment)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (amount == 0) revert ZeroAmount();
        if (auctionsOpenAt == 0) revert AuctionNotOpen();
        if (amount > availableRelease()) revert ReleaseLimit();
        _checkpointSale();
        ContinuousAuction.State memory curve = saleCurve;
        _alignSaleFloor(curve);
        payment = ContinuousAuction.buy(curve, amount);
        _checkSaleDepth(curve);
        uint256 backing = backingRequired(amount);
        payment = FixedPointMathLib.max(payment, _saleMinimum(backing));
        // Two thirds of the premium funds liquidity; reserves keep the rest, raising NAV.
        uint256 funding = (payment - backing) * 2 / 3;
        backing = payment - funding;
        if (payment > maximumPayment) revert AboveMaximum();
        saleCurve = curve;
        releaseBucket.scaledCredit -= amount * 1 days;
        totalReleased += amount;
        _receiveBacking(msg.sender, payment);
        reserveCash += backing;
        unreleasedSupply -= amount;
        if (funding != 0) {
            SafeTransferLib.safeTransfer(backingAsset, liquidity, funding);
            ISzrLiquidity(liquidity).recordFunding(funding);
        }
        SafeTransferLib.safeTransfer(address(token), msg.sender, amount);
        emit Released(msg.sender, amount, backing);
        emit AuctionPurchased(msg.sender, amount, payment, backing, funding);
    }

    /// @dev With zero active supply the first (even dust) holder would capture the whole gift.
    function donateBacking(uint256 amount) external nonReentrant live {
        if (amount == 0) revert ZeroAmount();
        if (activeSupply() == 0) revert NoActiveSupply();
        _receiveBacking(msg.sender, amount);
        reserveCash += amount;
        emit BackingDonated(msg.sender, amount);
    }

    /// @notice Exit an unencumbered token claim immediately at the exact current NAV ratio.
    function redeem(uint256 amount, uint256 minimumBacking)
        external
        nonReentrant
        live
        returns (uint256 backing)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 supply = activeSupply();
        if (amount > supply) revert InsufficientInventory();
        backing = FixedPointMathLib.fullMulDiv(amount, backingAmount(), supply);
        if (backing < minimumBacking) revert BelowMinimum();
        if (backing > reserveCash) revert InsufficientCash();
        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), amount);
        _retire(amount);
        reserveCash -= backing;
        if (backing != 0) SafeTransferLib.safeTransfer(backingAsset, msg.sender, backing);
        emit Redeemed(msg.sender, amount, backing);
    }

    /// @notice Retires donated SZR into unreleased public auction inventory.
    function donateSzr(uint256 amount) external nonReentrant live {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = SafeTransferLib.balanceOf(address(token), address(this));
        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), amount);
        uint256 afterBalance = SafeTransferLib.balanceOf(address(token), address(this));
        if (afterBalance != beforeBalance + amount) revert TransferAmountMismatch();
        _retire(amount);
        emit SzrDonated(msg.sender, amount);
    }

    /// @notice Only the fixed liquidity controller returns authenticated trading-fee tokens.
    function recycle(uint256 amount) external nonReentrant live {
        if (msg.sender != liquidity) revert NotLiquidity();
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(address(token), msg.sender, address(this), amount);
        _retire(amount);
        emit InventoryRecycled(amount);
    }

    /// @notice Realized WETH fees: 67% reserves, 33% team beneficiary.
    /// Rounding dust remains in reserves. Unconverted pool tokens are not backing.
    function recognizeFees(uint256 amount) external nonReentrant live {
        if (msg.sender != feeJar) revert NotFeeJar();
        if (amount == 0) revert ZeroAmount();
        uint256 accounted = reserveCash;
        uint256 held = SafeTransferLib.balanceOf(backingAsset, address(this));
        if (held < accounted + amount) revert AccountingMismatch();
        uint256 teamFee = economics.liquidityTeamFee(amount);
        // With no holders, a reserve share would simply belong to whoever next bought a single
        // unit. Nobody has a claim on it, so the whole amount goes to the team instead.
        if (activeSupply() == 0) teamFee = amount;
        if (teamFee != 0) {
            uint256 beforeBalance = SafeTransferLib.balanceOf(backingAsset, address(economics));
            SafeTransferLib.safeTransfer(backingAsset, address(economics), teamFee);
            if (
                SafeTransferLib.balanceOf(backingAsset, address(economics))
                    != beforeBalance + teamFee
            ) {
                revert TransferAmountMismatch();
            }
            economics.recordFees(teamFee);
        }
        reserveCash += amount - teamFee;
        emit FeesAllocated(amount, amount - teamFee, teamFee);
    }

    /// @notice One loan per owner. An additional draw is checked against total resulting debt.
    function borrow(uint256 collateralAdded, uint256 principalAdded)
        external
        nonReentrant
        live
    {
        if (migrationRemaining != 0) revert MigrationOpen();
        if (principalAdded == 0) revert ZeroAmount();
        Loan storage loan = loans[msg.sender];
        if (loan.principal != 0) {
            if (block.timestamp >= loan.expiresAt) revert LoanExpired();
        }
        uint256 collateral = loan.collateral + collateralAdded;
        uint256 principal = loan.principal + principalAdded;
        uint256 supply = activeSupply();
        if (supply == 0) revert AboveNAV();
        uint256 capacity = FixedPointMathLib.fullMulDiv(collateral, backingAmount(), supply);
        if (principal > capacity) revert AboveNAV();
        if (principalAdded > reserveCash) revert InsufficientCash();
        uint256 fee = FixedPointMathLib.fullMulDivUp(principalAdded, 1, 100);
        if (fee >= principalAdded) revert ZeroAmount();
        if (collateralAdded != 0) {
            SafeTransferLib.safeTransferFrom(
                address(token), msg.sender, address(this), collateralAdded
            );
        }
        loan.collateral = collateral;
        loan.principal = principal;
        loan.expiresAt = block.timestamp + INACTIVITY_SECONDS;
        pledgedSupply += collateralAdded;
        loanPrincipal += principalAdded;
        reserveCash -= principalAdded;
        reserveCash += fee;
        SafeTransferLib.safeTransfer(backingAsset, msg.sender, principalAdded - fee);
        emit Borrowed(msg.sender, collateralAdded, principalAdded, fee);
    }

    /// @notice Repay principal and make proportional collateral reclaimable without moving it.
    function repay(uint256 principal) external nonReentrant live {
        _repay(msg.sender, principal);
    }

    /// @notice Return only the collateral freed by this repayment; older claims stay intact.
    function repayAndReclaim(uint256 principal) external nonReentrant live {
        uint256 collateral = _repay(msg.sender, principal);
        if (collateral != 0) _reclaim(msg.sender, collateral);
    }

    function reclaimCollateral(uint256 amount) external nonReentrant live {
        _reclaim(msg.sender, amount);
    }

    /// @dev Shared by the separate and atomic paths so debt rounding cannot diverge.
    function _repay(address owner, uint256 principal) internal returns (uint256 collateral) {
        Loan storage loan = loans[owner];
        if (loan.principal == 0) revert NoLoan();
        if (principal == 0) revert ZeroAmount();
        if (principal > loan.principal) revert AbovePrincipal();
        collateral = FixedPointMathLib.fullMulDiv(loan.collateral, principal, loan.principal);
        _receiveBacking(owner, principal);
        loan.principal -= principal;
        loan.collateral -= collateral;
        loan.expiresAt = block.timestamp + INACTIVITY_SECONDS;
        loanPrincipal -= principal;
        pledgedSupply -= collateral;
        reserveCash += principal;
        reclaimableCollateral[owner] += collateral;
        totalReclaimable += collateral;
        if (loan.principal == 0) delete loans[owner];
        emit Repaid(owner, principal, collateral);
    }

    function _reclaim(address owner, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (amount > reclaimableCollateral[owner]) revert InsufficientReclaimable();
        reclaimableCollateral[owner] -= amount;
        totalReclaimable -= amount;
        SafeTransferLib.safeTransfer(address(token), owner, amount);
        emit CollateralReclaimed(owner, amount);
    }

    function poke() external nonReentrant live {
        Loan storage loan = loans[msg.sender];
        if (loan.principal == 0) revert NoLoan();
        if (block.timestamp >= loan.expiresAt) revert LoanExpired();
        loan.expiresAt = block.timestamp + INACTIVITY_SECONDS;
        emit Poked(msg.sender, loan.expiresAt);
    }

    /// @notice Anyone can settle expiry. Only the debt's NAV-equivalent collateral is recycled.
    function settleExpired(address owner) external nonReentrant live {
        Loan memory loan = loans[owner];
        if (loan.principal == 0) revert NoLoan();
        if (block.timestamp < loan.expiresAt) revert NotExpired();
        uint256 supply = activeSupply();
        uint256 backing = backingAmount();
        uint256 recycled = FixedPointMathLib.fullMulDivUp(loan.principal, supply, backing);
        if (recycled > loan.collateral) revert UncoveredLoan();
        uint256 returned = loan.collateral - recycled;
        _retire(recycled);
        delete loans[owner];
        loanPrincipal -= loan.principal;
        pledgedSupply -= loan.collateral;
        if (returned != 0) SafeTransferLib.safeTransfer(address(token), owner, returned);
        emit LoanSettled(owner, loan.principal, recycled, returned);
    }

    /// @dev Shared retirement updates active claims exactly once, including an empty restart.
    function _retire(uint256 amount) internal {
        _checkpointSale();
        uint256 supply = activeSupply();
        if (amount > supply) revert InsufficientInventory();
        if (amount == supply) {
            emptyBackingNumerator = backingAmount();
            emptySupplyDenominator = supply;
        }
        unreleasedSupply += amount;
        // While migration is open a retired token frees its migration slot. Otherwise
        // cycling migrate and redeem would use up the allowance and end migration for everyone.
        uint256 remaining = migrationRemaining;
        if (remaining == 0) return;
        migrationRemaining = FixedPointMathLib.min(remaining + amount, migrationAllocation);
    }

    function _receiveBacking(address payer, uint256 amount) internal {
        uint256 beforeBalance = SafeTransferLib.balanceOf(backingAsset, address(this));
        SafeTransferLib.safeTransferFrom(backingAsset, payer, address(this), amount);
        uint256 afterBalance = SafeTransferLib.balanceOf(backingAsset, address(this));
        if (afterBalance != beforeBalance + amount) revert TransferAmountMismatch();
    }

    function releaseRatePerDay() external view returns (uint256) {
        uint256 opening = auctionsOpenAt;
        uint256 elapsed = block.timestamp > opening ? block.timestamp - opening : 0;
        if (opening == 0) return RELEASE_PER_DAY;
        return ReleaseSchedule.ratePerDay(elapsed);
    }

    function quote(uint256 amount)
        external
        view
        returns (uint256 payment, uint256 backing, uint256 funding)
    {
        if (amount == 0) revert ZeroAmount();
        if (amount > availableRelease()) revert ReleaseLimit();
        ContinuousAuction.State memory curve = _projectSale();
        _alignSaleFloor(curve);
        payment = ContinuousAuction.buy(curve, amount);
        _checkSaleDepth(curve);
        backing = backingRequired(amount);
        payment = FixedPointMathLib.max(payment, _saleMinimum(backing));
        funding = (payment - backing) * 2 / 3;
        backing = payment - funding;
    }

    function price() external view returns (uint256 result) {
        result = FixedPointMathLib.max(
            ContinuousAuction.price(_projectSale()), _saleMinimum(backingRequired(WAD))
        );
    }

    function auctionState() external view returns (ContinuousAuction.State memory) {
        return saleCurve;
    }

    function _projectSale() internal view returns (ContinuousAuction.State memory curve) {
        curve = saleCurve;
        uint256 opening = auctionsOpenAt;
        uint256 available = availableRelease();
        uint256 start = saleUpdatedAt > opening ? saleUpdatedAt : opening;
        uint256 ready = ReleaseSchedule.decayStartsAt(releaseBucket, opening);
        if (start < ready) start = ready;
        uint256 elapsed;
        if (publicInventory() != 0) {
            if (opening != 0) {
                if (block.timestamp > start) elapsed = block.timestamp - start;
            }
        }
        ContinuousAuction.project(curve, elapsed, available + saleBuffer);
    }

    function _checkpointSale() internal {
        saleCurve = _projectSale();
        releaseBucket.checkpoint(auctionsOpenAt);
        saleUpdatedAt = block.timestamp;
    }

    function _checkSaleDepth(ContinuousAuction.State memory curve) internal view {
        ContinuousAuction.State memory projected = ContinuousAuction.State(
            curve.depth, curve.floorWad, curve.excess, curve.deficit, curve.decayMass
        );
        ContinuousAuction.project(projected, 0, token.totalSupply() + saleBuffer);
    }

    /// @dev No SZR is sold below one and a half times its NAV backing.
    function _saleMinimum(uint256 backing) internal pure returns (uint256) {
        return FixedPointMathLib.mulDivUp(backing, 3, 2);
    }

    /// @dev A fill at the sale floor must still add constant-product demand pressure.
    function _alignSaleFloor(ContinuousAuction.State memory curve) internal view {
        uint256 floor = _saleMinimum(backingRequired(WAD));
        if (ContinuousAuction.price(curve) >= floor) return;
        curve.floorWad = floor;
        curve.excess = 0;
        curve.deficit = 0;
        curve.decayMass = 0;
    }
}
