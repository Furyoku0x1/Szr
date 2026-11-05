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
    uint256 public constant RELEASE_PER_DAY = 500_000e18;
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
    uint256 public migrationAllocation;
    uint256 public migrationRemaining;
    bool public initialized;
    bool public launched;
    uint256 public startedAt;

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

    event MigrationClosed(uint256 unusedAllocation);
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

    /// @notice Reserves full 1:1 migration and records the holder-funded initial liquidity target.
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
        if (liquidityTokens > allocation) revert InsufficientInventory();
        migration = module;
        initialLiquidityTarget = liquidityTokens;
        migrationAllocation = allocation;
        migrationRemaining = migrationAllocation;
        emit MigrationConfigured(module, migrationAllocation, liquidityTokens);
    }

    /// @notice Ends migration permanently; unused reserved tokens join the scheduled public sale.
    function closeMigration() external nonReentrant live {
        if (msg.sender != initializer) revert NotInitializer();
        uint256 unused = migrationRemaining;
        if (unused == 0) revert MigrationNotOpen();
        _checkpointSale();
        migrationRemaining = 0;
        emit MigrationClosed(unused);
    }

    /// @notice Receives actual legacy proceeds and releases reserved tokens without a NAV minimum.
    /// @dev Migration can lower NAV. Public auction issuance retains its backing requirement.
    function releaseMigration(address owner, uint256 amount, uint256 backing)
        external
        nonReentrant
        live
    {
        if (msg.sender != migration) revert NotMigration();
        if (owner == address(0)) revert ZeroAddress();
        if (owner == address(this)) revert InvalidModule();
        if (amount == 0) revert ZeroAmount();
        if (amount > migrationRemaining) revert InsufficientInventory();
        _receiveBacking(msg.sender, backing);
        reserveCash += backing;
        migrationRemaining -= amount;
        unreleasedSupply -= amount;
        SafeTransferLib.safeTransfer(address(token), owner, amount);
        emit MigrationReleased(owner, amount, backing);
        if (migrationRemaining == 0) emit MigrationClosed(0);
    }

    /// @notice Starts migration and the sale clock without activating a separate LP allocation.
    function launch() external nonReentrant {
        if (msg.sender != initializer) revert NotInitializer();
        if (!initialized) revert NotInitialized();
        if (launched) revert AlreadyLaunched();
        launched = true;
        startedAt = block.timestamp;
        releaseBucket.updatedAt = auctionsOpenAt();
        saleUpdatedAt = auctionsOpenAt();
        ISzrLiquidity(liquidity).onLaunch();
        emit Launched(startedAt);
    }

    function auctionsOpenAt() public view returns (uint256) {
        if (!launched) return 0;
        return startedAt + 1 days;
    }

    function activeSupply() public view returns (uint256) {
        return token.totalSupply() - unreleasedSupply;
    }

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
            ReleaseSchedule.projected(releaseBucket, auctionsOpenAt(), block.timestamp) / 1 days;
    }

    function releaseReadyAt() external view returns (uint256) {
        return ReleaseSchedule.readyAt(releaseBucket, auctionsOpenAt());
    }

    function releaseDecayStartsAt() external view returns (uint256) {
        return ReleaseSchedule.decayStartsAt(releaseBucket, auctionsOpenAt());
    }

    function releaseState() external view returns (ReleaseSchedule.State memory) {
        return releaseBucket;
    }

    function availableRelease() public view returns (uint256) {
        uint256 credit = releaseCredit();
        uint256 inventory = publicInventory();
        return credit < inventory ? credit : inventory;
    }

    /// @notice Single continuous SZR/WETH sale. Reserve claims are funded before treasury WETH.
    function buy(uint256 amount, uint256 maximumPayment, uint256 deadline)
        external
        nonReentrant
        live
        returns (uint256 payment)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < auctionsOpenAt()) revert AuctionNotOpen();
        if (amount > availableRelease()) revert ReleaseLimit();
        _checkpointSale();
        ContinuousAuction.State memory curve = saleCurve;
        _alignSaleFloor(curve);
        payment = ContinuousAuction.buy(curve, amount);
        _checkSaleDepth(curve);
        uint256 backing = backingRequired(amount);
        if (payment < backing) payment = backing;
        if (payment > maximumPayment) revert AboveMaximum();
        saleCurve = curve;
        releaseBucket.scaledCredit -= amount * 1 days;
        totalReleased += amount;
        _receiveBacking(msg.sender, payment);
        reserveCash += backing;
        unreleasedSupply -= amount;
        uint256 funding = payment - backing;
        if (funding != 0) {
            SafeTransferLib.safeTransfer(backingAsset, liquidity, funding);
            ISzrLiquidity(liquidity).recordFunding(funding);
        }
        SafeTransferLib.safeTransfer(address(token), msg.sender, amount);
        emit Released(msg.sender, amount, backing);
        emit AuctionPurchased(msg.sender, amount, payment, backing, funding);
    }

    function donateBacking(uint256 amount) external nonReentrant live {
        if (amount == 0) revert ZeroAmount();
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

    /// @notice Realized WETH fees: 67% reserves, 33% immutable team beneficiary.
    /// Rounding dust remains in reserves. Unconverted pool tokens are not backing.
    function recognizeFees(uint256 amount) external nonReentrant live {
        if (msg.sender != feeJar) revert NotFeeJar();
        if (amount == 0) revert ZeroAmount();
        uint256 accounted = reserveCash;
        uint256 held = SafeTransferLib.balanceOf(backingAsset, address(this));
        if (held < accounted + amount) revert AccountingMismatch();
        uint256 teamFee = economics.liquidityTeamFee(amount);
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
    }

    function _receiveBacking(address payer, uint256 amount) internal {
        uint256 beforeBalance = SafeTransferLib.balanceOf(backingAsset, address(this));
        SafeTransferLib.safeTransferFrom(backingAsset, payer, address(this), amount);
        uint256 afterBalance = SafeTransferLib.balanceOf(backingAsset, address(this));
        if (afterBalance != beforeBalance + amount) revert TransferAmountMismatch();
    }

    function releaseRatePerDay() external view returns (uint256) {
        uint256 opening = auctionsOpenAt();
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
        if (payment < backing) payment = backing;
        funding = payment - backing;
    }

    function price() external view returns (uint256 result) {
        result = ContinuousAuction.price(_projectSale());
        uint256 backing = backingRequired(WAD);
        if (result < backing) result = backing;
    }

    function auctionState() external view returns (ContinuousAuction.State memory) {
        return saleCurve;
    }

    function _projectSale() internal view returns (ContinuousAuction.State memory curve) {
        curve = saleCurve;
        uint256 opening = auctionsOpenAt();
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
        releaseBucket.checkpoint(auctionsOpenAt());
        saleUpdatedAt = block.timestamp;
    }

    function _checkSaleDepth(ContinuousAuction.State memory curve) internal view {
        ContinuousAuction.State memory projected = ContinuousAuction.State(
            curve.depth, curve.floorWad, curve.excessTime, curve.decayMass
        );
        ContinuousAuction.project(projected, 0, token.totalSupply() + saleBuffer);
    }

    /// @dev A fill at the backing floor must still add constant-product demand pressure.
    function _alignSaleFloor(ContinuousAuction.State memory curve) internal view {
        uint256 floor = backingRequired(WAD);
        if (ContinuousAuction.price(curve) >= floor) return;
        curve.floorWad = floor;
        curve.excessTime = 0;
        curve.decayMass = 0;
    }
}
