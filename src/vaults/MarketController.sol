// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ArbitrageApi } from "../arbitrage/ArbitrageApi.sol";
import { IMarketController, IVaultLink } from "../interfaces/IMarketController.sol";

/// @notice Owns one arbitrage-hook market, is its profit recipient, and splits what it
/// receives across the market's pair vaults by weight. The curator runs the market through
/// it, but can never redirect its profit: `setRecipient` is not forwarded.
/// @dev The controller takes no fee. Each vault charges its own, once. What the weights
/// leave over is the curator's, kept here until claimed.
/// @dev A vault-triggered push is capped by the vault's gas limit and may leave distribution
/// to a direct `distribute`. A share pending for a vault that always refuses a token stays in
/// the controller.
/// @dev Structural changes (tokens, untracking, limits, handing the market on, vault
/// weights and new vaults after the first) wait `CONTROL_DELAY` in a queue, so depositors
/// can leave first. A queued item expires `GRACE` after it is ready, so an old one cannot be
/// run long after the depositors last looked.
contract MarketController is IMarketController {
    uint256 public constant CONTROL_DELAY = 3 days;
    uint256 public constant GRACE = 7 days;
    // Gas a token may use to report a balance or to send, so one that burns gas cannot stop
    // the split.
    uint256 internal constant BALANCE_GAS = 50_000;
    uint256 internal constant SEND_GAS = 100_000;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_VAULTS = 16;

    // Spelled out, since the hook's API type does not expose these as members. A test
    // checks each against the hook's own selector.
    bytes4 internal constant SETLEADERS_SIG =
        bytes4(keccak256("setLeaders(uint256,address,address,bytes32[])"));
    bytes4 internal constant SETCONNECTOR_SIG =
        bytes4(keccak256("setConnector(uint256,(address,address,uint24,int24,address),bool)"));
    bytes4 internal constant SETMINIMUMPROFIT_SIG =
        bytes4(keccak256("setMinimumProfit(uint256,address,uint128)"));
    bytes4 internal constant SETPRICERGAS_SIG =
        bytes4(keccak256("setPricerGas(uint256,uint32)"));
    bytes4 internal constant CREATEPOOL_SIG =
        bytes4(keccak256("createPool(uint256,(address,address,uint24,int24,address),uint160)"));
    bytes4 internal constant ADDVENUE_SIG =
        bytes4(keccak256("addVenue(uint256,(address,address,uint24,int24,address))"));
    bytes4 internal constant SETTOKENS_SIG = bytes4(keccak256("setTokens(uint256,address[])"));
    bytes4 internal constant UNTRACK_SIG = bytes4(keccak256("untrack(uint256,bytes32)"));
    bytes4 internal constant SETLIMITS_SIG =
        bytes4(keccak256("setLimits(uint256,address,uint32,uint128,uint64)"));
    bytes4 internal constant NOMINATEOWNER_SIG =
        bytes4(keccak256("nominateOwner(uint256,address)"));
    bytes4 internal constant RETRACK = bytes4(keccak256("retrack(bytes32)"));
    uint8 internal constant NONE = 0;
    uint8 internal constant IMMEDIATE = 1;
    uint8 internal constant DELAYED = 2;
    uint8 internal constant SELF = 3;

    ArbitrageApi public immutable hook;
    uint256 public immutable market;
    address public immutable factory;

    address public curator;
    address public pendingCurator;
    bool public initialized;
    uint256 public totalWeight;
    address[] internal registry;
    mapping(address vault => bool) public isVault;
    mapping(address vault => uint16) public weights;
    /// What the weights left for the curator, per token, not yet claimed.
    mapping(address token => uint256) public owed;
    /// What failed to reach a vault, per vault and token, and its sum per token. It is kept
    /// out of the next split and retried for the same vault.
    mapping(address vault => mapping(address token => uint256)) public pending;
    mapping(address token => uint256) public pendingTotal;
    /// When a queued call may run, by the hash of the call.
    mapping(bytes32 key => uint256) public readyAt;

    constructor(
        ArbitrageApi arbitrageHook,
        uint256 marketId,
        address curator_,
        address factory_
    ) {
        if (curator_ == address(0)) revert NotCurator();
        hook = arbitrageHook;
        market = marketId;
        curator = curator_;
        factory = factory_;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert NotCurator();
        _;
    }

    modifier live() {
        if (!initialized) revert NotInitialized();
        _;
    }

    /// @notice Takes the market, which the curator must have nominated this controller for,
    /// and makes the controller its recipient. Once.
    function initialize() external {
        if (msg.sender != curator) {
            if (msg.sender != factory) revert NotCurator();
        }
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        hook.acceptOwnership(market);
        hook.setRecipient(market, address(this));
        emit Initialized(market);
    }

    // Rewards.

    /// @inheritdoc IMarketController
    /// @dev A vault that cannot be paid keeps its share here as `pending`, which is left out
    /// of the next split and retried for that vault alone. The curator's part is booked at
    /// once, from the new money only.
    function distribute(address[] calldata tokens) external {
        uint256 rest = BPS - totalWeight;
        for (uint256 index; index < tokens.length; index++) {
            address token = tokens[index];
            uint256 held = _balance(token);
            uint256 reserved = owed[token] + pendingTotal[token];
            // A balance below what is reserved (a rebasing token) splits nothing.
            uint256 fresh = held > reserved ? held - reserved : 0;
            uint256 mine = fresh * rest / BPS;
            owed[token] += mine;
            uint256 sent;
            for (uint256 slot; slot < registry.length; slot++) {
                sent += _pay(token, registry[slot], fresh);
            }
            emit Distributed(token, sent, mine);
        }
    }

    /// @dev Pays a vault its share of `fresh` and anything pending for it, and keeps what
    /// could not be sent. Returns what was sent.
    function _pay(address token, address vault, uint256 fresh) internal returns (uint256) {
        uint256 old = pending[vault][token];
        uint256 amount = fresh * weights[vault] / BPS + old;
        if (amount == 0) return 0;
        bool ok = _send(token, vault, amount);
        uint256 kept = ok ? 0 : amount;
        pending[vault][token] = kept;
        pendingTotal[token] = pendingTotal[token] + kept - old;
        return ok ? amount : 0;
    }

    /// @dev A balance read with a gas cap. A token that fails, or reports 2^128 or more,
    /// reads as zero: splitting that much would overflow and stop every other token's split.
    function _balance(address token) internal view returns (uint256 amount) {
        (bool ok, bytes memory data) = token.staticcall{ gas: BALANCE_GAS }(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        if (!ok) return 0;
        if (data.length < 32) return 0;
        amount = abi.decode(data, (uint256));
        if (amount > type(uint128).max) return 0;
    }

    /// @notice Sends the curator's remainder of `token` to `to`.
    function claim(address token, address to) external onlyCurator {
        uint256 amount = owed[token];
        owed[token] = 0;
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Claimed(token, to, amount);
    }

    /// @dev A transfer that fails is not an error: the share stays here as `pending`.
    function _send(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory data) = token.call{ gas: SEND_GAS }(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        if (!ok) return false;
        if (data.length == 0) return true;
        if (data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    // Vault registry.

    function vaultCount() external view returns (uint256) {
        return registry.length;
    }

    function vaultAt(uint256 index) external view returns (address) {
        return registry[index];
    }

    /// @notice Adds a pair vault of this market that names this controller as its own. The
    /// first is immediate; later ones go through `queue`.
    function addVault(address vault, uint16 weight) external live {
        _authorise(registry.length == 0);
        if (isVault[vault]) revert AlreadyAdded();
        if (registry.length >= MAX_VAULTS) revert TooManyVaults();
        if (IVaultLink(vault).controller() != address(this)) revert NotAVault();
        if (IVaultLink(vault).market() != market) revert NotAVault();
        isVault[vault] = true;
        registry.push(vault);
        _setWeight(vault, weight);
        emit VaultAdded(vault, weight);
    }

    /// @notice Sets a vault's weight to zero. The vault itself keeps working, and stays
    /// listed so it can be given a weight again.
    function retireVault(address vault) external {
        _authorise(false);
        if (!isVault[vault]) revert NotAVault();
        _setWeight(vault, 0);
    }

    function setWeight(address vault, uint16 weight) external {
        _authorise(false);
        if (!isVault[vault]) revert NotAVault();
        _setWeight(vault, weight);
    }

    function _setWeight(address vault, uint16 weight) internal {
        uint256 next = totalWeight - weights[vault] + weight;
        if (next > BPS) revert WeightTooHigh();
        totalWeight = next;
        weights[vault] = weight;
        emit WeightSet(vault, weight);
    }

    /// @dev Open to the curator when `immediate`, and otherwise only to the controller
    /// itself, which is how a queued call reaches here.
    function _authorise(bool immediate) internal view {
        if (msg.sender == address(this)) return;
        if (!immediate) revert Timelocked();
        if (msg.sender != curator) revert NotCurator();
    }

    // The market, through the controller.

    /// @notice Runs an immediate call on the hook as the market's owner.
    function forward(bytes calldata call) external onlyCurator live {
        if (_kind(call) != IMMEDIATE) revert NotAllowed();
        _checkMarket(call);
        _hook(call);
        emit Forwarded(bytes4(call[:4]));
    }

    /// @notice Queues a timelocked call: on the hook, or on this controller's own vault
    /// and weight functions.
    function queue(bytes calldata call) external onlyCurator live {
        uint8 kind = _kind(call);
        if (kind != DELAYED) {
            if (kind != SELF) revert NotAllowed();
        }
        if (kind == DELAYED) _checkMarket(call);
        bytes32 key = keccak256(call);
        if (readyAt[key] != 0) revert AlreadyQueued();
        uint256 when = block.timestamp + CONTROL_DELAY;
        readyAt[key] = when;
        emit Queued(key, call, when);
    }

    function execute(bytes calldata call) external onlyCurator live {
        bytes32 key = keccak256(call);
        uint256 when = readyAt[key];
        if (when == 0) revert NotQueued();
        if (block.timestamp < when) revert NotReady();
        if (block.timestamp > when + GRACE) revert Expired();
        delete readyAt[key];
        if (_kind(call) == SELF) {
            _run(address(this), call);
        } else {
            _hook(call);
        }
        emit Executed(key);
    }

    function cancel(bytes calldata call) external onlyCurator {
        bytes32 key = keccak256(call);
        if (readyAt[key] == 0) revert NotQueued();
        delete readyAt[key];
        emit Cancelled(key);
    }

    function _hook(bytes calldata call) internal {
        _run(address(hook), call);
    }

    function _run(address target, bytes calldata call) internal {
        (bool ok, bytes memory data) = target.call(call);
        if (ok) return;
        assembly ("memory-safe") {
            revert(add(data, 32), mload(data))
        }
    }

    /// @dev Every forwarded call but `retrack` (which names a pool, and which the hook
    /// checks against its pool's own market) takes the market id first, and it must be ours.
    function _checkMarket(bytes calldata call) internal view {
        if (bytes4(call[:4]) == RETRACK) return;
        if (abi.decode(call[4:36], (uint256)) != market) revert WrongMarket();
    }

    /// @dev What a selector may do. `setRecipient` is in none of these on purpose.
    function _kind(bytes calldata call) internal pure returns (uint8) {
        if (call.length < 36) revert BadCall();
        bytes4 pick = bytes4(call[:4]);
        if (pick == SETLEADERS_SIG) return IMMEDIATE;
        if (pick == SETCONNECTOR_SIG) return IMMEDIATE;
        if (pick == SETMINIMUMPROFIT_SIG) return IMMEDIATE;
        if (pick == SETPRICERGAS_SIG) return IMMEDIATE;
        if (pick == CREATEPOOL_SIG) return IMMEDIATE;
        if (pick == ADDVENUE_SIG) return IMMEDIATE;
        if (pick == RETRACK) return IMMEDIATE;
        if (pick == SETTOKENS_SIG) return DELAYED;
        if (pick == UNTRACK_SIG) return DELAYED;
        if (pick == SETLIMITS_SIG) return DELAYED;
        if (pick == NOMINATEOWNER_SIG) return DELAYED;
        if (pick == this.addVault.selector) return SELF;
        if (pick == this.retireVault.selector) return SELF;
        if (pick == this.setWeight.selector) return SELF;
        return NONE;
    }

    // Curator handover.

    function nominateCurator(address nominee) external onlyCurator {
        pendingCurator = nominee;
        emit CuratorNominated(nominee);
    }

    function acceptCurator() external {
        if (msg.sender != pendingCurator) revert NotCurator();
        curator = msg.sender;
        pendingCurator = address(0);
        emit CuratorSet(msg.sender);
    }
}
