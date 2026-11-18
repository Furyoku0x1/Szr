// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice What a pair vault asks of its market's controller, and what anyone can do to it.
interface IMarketController {
    event Initialized(uint256 indexed market);
    event Distributed(address indexed token, uint256 toVaults, uint256 toCurator);
    event Claimed(address indexed token, address indexed to, uint256 amount);
    event VaultAdded(address indexed vault, uint16 weight);
    event WeightSet(address indexed vault, uint16 weight);
    event Forwarded(bytes4 indexed selector);
    event Queued(bytes32 indexed key, bytes call, uint256 readyAt);
    event Executed(bytes32 indexed key);
    event Cancelled(bytes32 indexed key);
    event CuratorNominated(address indexed nominee);
    event CuratorSet(address indexed curator);

    error NotCurator();
    error NotAllowed();
    error WrongMarket();
    error BadCall();
    error AlreadyInitialized();
    error NotInitialized();
    error Timelocked();
    error NotQueued();
    error NotReady();
    error Expired();
    error AlreadyQueued();
    error NotAVault();
    error AlreadyAdded();
    error TooManyVaults();
    error WeightTooHigh();

    /// @notice Splits the controller's balance of each token across the vaults by weight.
    /// Open to anyone. The curator's remainder is kept as a claimable balance.
    function distribute(address[] calldata tokens) external;
}

/// @notice The two facts a controller checks before it adds a vault.
interface IVaultLink {
    function controller() external view returns (address);
    function market() external view returns (uint256);
}
