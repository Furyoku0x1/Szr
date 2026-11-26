// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { ISzrLiquidity } from "../../src/interfaces/ISzrModules.sol";
import { IIndexHook } from "../../src/interfaces/IIndexHook.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../../src/index/IndexPoolFactory.sol";

/// @notice Test token: any decimals, and switches for a fee on transfer, a pause, and one
/// call back into some contract during its next transfer.
contract IndexToken is ERC20 {
    uint8 internal immutable places;
    uint256 public feeBps;
    /// Gas every transfer burns, to stand in for a token whose transfers are expensive.
    uint256 public transferBurn;
    bool public paused;
    address public reenterTarget;
    bytes internal reenterData;
    bool public reentered;
    bool public reenterOk;
    bytes public reenterResult;

    error Paused();

    constructor(uint8 places_) {
        places = places_;
    }

    function name() public pure override returns (string memory) {
        return "Index test token";
    }

    function symbol() public pure override returns (string memory) {
        return "ITT";
    }

    function decimals() public view override returns (uint8) {
        return places;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function setTransferBurn(uint256 burn) external {
        transferBurn = burn;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal override {
        if (from == address(0)) return;
        if (to == address(0)) return;
        if (paused) revert Paused();
        _spend(transferBurn);
        address target = reenterTarget;
        if (target == address(0)) return;
        reenterTarget = address(0);
        reentered = true;
        (reenterOk, reenterResult) = target.call(reenterData);
    }

    function _spend(uint256 burn) internal view {
        if (burn == 0) return;
        uint256 stop = gasleft() - burn;
        while (gasleft() > stop) { }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (feeBps == 0) return;
        if (from == address(0)) return;
        if (to == address(0)) return;
        _burn(to, amount * feeBps / 10_000);
    }
}

contract IndexManager {
    address public manager;

    function setManager(address manager_) external {
        manager = manager_;
    }
}

/// @notice A hook for tests. One mode at a time: record only, revert, burn every unit of
/// gas, call back into the pool, balance honestly (swap and donate), sandwich the swapper,
/// return a huge blob, do nothing at all, or burn all its gas before and record after. The
/// blocking modes revert `Blocked()` before or after, with extra or missing bytes, or return
/// its four bytes normally, or revert 100 KB that start with them.
contract MockIndexHook is IIndexHook {
    enum Mode {
        Record,
        Revert,
        Burn,
        Reenter,
        Honest,
        Sandwich,
        Huge,
        Idle,
        BurnBefore,
        BlockBefore,
        BlockAfter,
        BlockLong,
        BlockShort,
        ReturnBlocked,
        HugeRevert
    }

    struct Call {
        bool before;
        address sender;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 gasAtEntry;
    }

    IndexPool public pool;
    Mode public mode;
    Call[] public calls;
    address public actIn;
    address public actOut;
    uint256 public actAmount;
    address public donateToken;
    uint256 public donateAmount;
    bytes public reenterData;
    bool public reenterOk;
    bytes public reenterResult;
    uint256 public bought;

    function setPool(IndexPool pool_) external {
        pool = pool_;
        address[] memory list = pool_.tokens();
        for (uint256 index; index < list.length; index++) {
            ERC20(list[index]).approve(address(pool_), type(uint256).max);
        }
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setAction(address tokenIn, address tokenOut, uint256 amount) external {
        actIn = tokenIn;
        actOut = tokenOut;
        actAmount = amount;
    }

    function setDonation(address token, uint256 amount) external {
        donateToken = token;
        donateAmount = amount;
    }

    function setReenter(bytes calldata data) external {
        reenterData = data;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    /// Lets tests trade as the hook, fee-free, without a prank.
    function swapAsHook(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool exactIn,
        uint256 limit
    ) external returns (uint256, uint256) {
        return pool.swap(
            tokenIn, tokenOut, amount, exactIn, limit, address(this), type(uint256).max
        );
    }

    function beforeSwap(address sender, address tokenIn, address tokenOut) external {
        uint256 entry = gasleft();
        if (mode == Mode.Idle) return;
        if (mode == Mode.BurnBefore) _burn();
        _refuse(true);
        calls.push(Call(true, sender, tokenIn, tokenOut, 0, 0, entry));
        if (mode == Mode.Revert) revert("hook");
        if (mode == Mode.Burn) _burn();
        if (mode == Mode.Reenter) {
            (reenterOk, reenterResult) = address(pool).call(reenterData);
        }
        if (mode == Mode.Honest) _balance();
        if (mode == Mode.Sandwich) {
            (, bought) = pool.swap(
                tokenIn, tokenOut, actAmount, true, 0, address(this), type(uint256).max
            );
        }
        if (mode == Mode.Huge) _huge();
    }

    function afterSwap(
        address sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    ) external {
        uint256 entry = gasleft();
        if (mode == Mode.Idle) return;
        calls.push(Call(false, sender, tokenIn, tokenOut, amountIn, amountOut, entry));
        _refuse(false);
        if (mode == Mode.Revert) revert("hook");
        if (mode == Mode.Burn) _burn();
        if (mode == Mode.Sandwich) {
            pool.swap(tokenOut, tokenIn, bought, true, 0, address(this), type(uint256).max);
        }
        if (mode == Mode.Huge) _huge();
    }

    function _balance() internal {
        if (actAmount != 0) {
            pool.swap(actIn, actOut, actAmount, true, 0, address(this), type(uint256).max);
        }
        if (donateAmount != 0) pool.donate(donateToken, donateAmount);
    }

    /// The blocking modes, before (`before`) or after the swap.
    function _refuse(bool before) internal view {
        bytes4 refusal = IIndexHook.Blocked.selector;
        if (before) {
            if (mode == Mode.BlockBefore) revert IIndexHook.Blocked();
            if (mode == Mode.BlockLong) {
                bytes memory long = abi.encodePacked(refusal, uint256(1));
                assembly {
                    revert(add(long, 32), mload(long))
                }
            }
            if (mode == Mode.BlockShort) {
                assembly {
                    mstore(0, refusal)
                    revert(0, 3)
                }
            }
            if (mode == Mode.HugeRevert) {
                assembly {
                    mstore(0, refusal)
                    revert(0, 100000)
                }
            }
            if (mode == Mode.ReturnBlocked) {
                assembly {
                    mstore(0, refusal)
                    return(0, 4)
                }
            }
            return;
        }
        if (mode == Mode.BlockAfter) revert IIndexHook.Blocked();
    }

    function _burn() internal pure {
        uint256 spin;
        while (true) {
            spin++;
        }
    }

    function _huge() internal pure {
        assembly {
            return(0, 100000)
        }
    }
}

/// @notice Deploys the factory, sorted test tokens and started pools.
contract IndexWorld is Test {
    IndexManager internal liquidity;
    IndexPoolFactory internal factory;
    address internal protocol = makeAddr("protocol");
    uint256 internal constant FEE = 3e15; // 0.3%
    uint256 internal constant FAR = type(uint256).max;

    function setUp() public virtual {
        liquidity = new IndexManager();
        liquidity.setManager(address(this));
        factory = new IndexPoolFactory(ISzrLiquidity(address(liquidity)), protocol);
    }

    /// Tokens with the given decimals, sorted by address as a pool needs them.
    function _tokens(uint8[] memory places) internal returns (address[] memory list) {
        list = new address[](places.length);
        for (uint256 index; index < places.length; index++) {
            list[index] = address(new IndexToken(places[index]));
        }
        for (uint256 index = 1; index < list.length; index++) {
            address moving = list[index];
            uint256 at = index;
            while (at > 0) {
                if (list[at - 1] < moving) break;
                list[at] = list[at - 1];
                at--;
            }
            list[at] = moving;
        }
    }

    function _create(
        address[] memory list,
        uint256[] memory weights,
        uint256 fee,
        address hook,
        uint32 gas
    ) internal returns (IndexPool pool) {
        if (hook != address(0)) factory.setHookApproved(hook, gas);
        pool = IndexPool(factory.create("Index", "IDX", list, weights, fee, hook, gas));
    }

    /// Starts `pool` with `units` whole tokens of each, and `shares` shares.
    function _start(IndexPool pool, uint256[] memory units, uint256 shares) internal {
        address[] memory list = pool.tokens();
        uint256[] memory amounts = new uint256[](list.length);
        for (uint256 index; index < list.length; index++) {
            amounts[index] = units[index] * 10 ** IndexToken(list[index]).decimals();
        }
        _fund(address(this), pool, amounts);
        pool.start(amounts, shares, FAR);
    }

    /// Mints `amounts` of the pool's tokens to `who` and approves the pool for them.
    function _fund(address who, IndexPool pool, uint256[] memory amounts) internal {
        address[] memory list = pool.tokens();
        for (uint256 index; index < list.length; index++) {
            IndexToken(list[index]).mint(who, amounts[index]);
            vm.prank(who);
            IndexToken(list[index]).approve(address(pool), type(uint256).max);
        }
    }

    function _fundAll(address who, IndexPool pool, uint256 amount) internal {
        uint256[] memory amounts = new uint256[](pool.tokens().length);
        for (uint256 index; index < amounts.length; index++) {
            amounts[index] = amount;
        }
        _fund(who, pool, amounts);
    }

    /// A started pool of `places.length` tokens with equal whole-token balances.
    function _pool(
        uint8[] memory places,
        uint256[] memory weights,
        uint256 units,
        address hook,
        uint32 gas
    ) internal returns (IndexPool pool) {
        pool = _create(_tokens(places), weights, FEE, hook, gas);
        uint256[] memory amounts = new uint256[](places.length);
        for (uint256 index; index < amounts.length; index++) {
            amounts[index] = units;
        }
        _start(pool, amounts, 1e24);
        _fundAll(address(this), pool, 1e40);
    }

    /// A created, unstarted pool, its tokens minted to and approved by this contract.
    function _unstarted(uint8[] memory places, uint256[] memory weights)
        internal
        returns (IndexPool pool)
    {
        pool = _create(_tokens(places), weights, FEE, address(0), 0);
        _fundAll(address(this), pool, 1e40);
    }

    function _pair(uint8 first, uint8 second) internal pure returns (uint8[] memory places) {
        places = new uint8[](2);
        places[0] = first;
        places[1] = second;
    }

    function _weights(uint256 first, uint256 second) internal pure returns (uint256[] memory) {
        uint256[] memory list = new uint256[](2);
        list[0] = first;
        list[1] = second;
        return list;
    }

    function _equal(uint256 count) internal pure returns (uint256[] memory list) {
        list = new uint256[](count);
        for (uint256 index; index < count; index++) {
            list[index] = 1e18 / count;
        }
    }

    function _same(uint8 place, uint256 count) internal pure returns (uint8[] memory list) {
        list = new uint8[](count);
        for (uint256 index; index < count; index++) {
            list[index] = place;
        }
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _zeros(uint256 count) internal pure returns (uint256[] memory) {
        return new uint256[](count);
    }

    function _maxes(uint256 count) internal pure returns (uint256[] memory list) {
        list = new uint256[](count);
        for (uint256 index; index < count; index++) {
            list[index] = FAR;
        }
    }

    function _swap(
        IndexPool pool,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool exactIn
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        uint256 limit = exactIn ? 0 : FAR;
        return pool.swap(tokenIn, tokenOut, amount, exactIn, limit, address(this), FAR);
    }

    /// Invariant 1: the pool holds at least everything it has recorded for anyone.
    function _assertSolvent(IndexPool pool, address[] memory holders) internal view {
        address[] memory list = pool.tokens();
        uint256[] memory balances = pool.balances();
        for (uint256 index; index < list.length; index++) {
            address token = list[index];
            uint256 recorded = balances[index] + pool.unreleased(token) + pool.owed(token);
            for (uint256 at; at < holders.length; at++) {
                recorded += pool.deferred(holders[at], token);
            }
            assertGe(ERC20(token).balanceOf(address(pool)), recorded, "solvent");
        }
    }

    function _balanceOf(address token, address who) internal view returns (uint256) {
        return ERC20(token).balanceOf(who);
    }
}
