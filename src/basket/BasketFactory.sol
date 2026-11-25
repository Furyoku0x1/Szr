// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StoredCode } from "../factories/VaultDeployers.sol";
import { Basket, IBasketProtocol } from "./Basket.sol";

/// @notice Deploys baskets and records them, so front ends and pools can tell a real one.
/// Anyone may create a basket. Every basket gets the same pool manager, arbitrage hook and
/// protocol recipient, which are fixed here.
/// @dev A basket's creation code does not fit inside the factory, so the deployer passes it in
/// once and it is kept in data contracts (`StoredCode`). `codeHash` lets anyone check it is
/// the audited `Basket`.
contract BasketFactory is StoredCode {
    IPoolManager public immutable poolManager;
    /// The one hook a leg's pool may have besides none. Zero allows hookless pools only.
    address public immutable arbitrageHook;
    /// The liquidity extension that receives every basket's protocol cut.
    address public immutable protocol;
    mapping(address basket => bool) public isBasket;

    error ZeroAddress();

    event BasketCreated(
        address indexed basket,
        address indexed creator,
        address indexed unit,
        uint256 legs,
        uint8 feeMode
    );

    constructor(
        IPoolManager poolManager_,
        address arbitrageHook_,
        address protocol_,
        bytes memory basketCode
    ) StoredCode(basketCode) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        if (protocol_ == address(0)) revert ZeroAddress();
        // The recipient must name a Liquidity, whose manager is the one allowed to pay it.
        if (IBasketProtocol(protocol_).liquidity() == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        arbitrageHook = arbitrageHook_;
        protocol = protocol_;
    }

    function create(
        string memory name,
        string memory symbol,
        address unit,
        uint8 feeMode,
        Basket.Leg[] memory legs
    ) external returns (address basket) {
        basket = _create(
            abi.encode(
                name,
                symbol,
                poolManager,
                unit,
                arbitrageHook,
                protocol,
                legs,
                msg.sender,
                feeMode
            )
        );
        isBasket[basket] = true;
        emit BasketCreated(basket, msg.sender, unit, legs.length, feeMode);
    }
}
