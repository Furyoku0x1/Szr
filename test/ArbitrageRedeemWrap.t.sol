// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { TryMeter } from "./utils/ArbitrageSizing.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { CyclePart } from "../src/arbitrage/ArbitrageCycle.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev A WETH whose `withdraw` also credits the hook one wei of WETH inside the pool
/// manager, as a wrapped link pool's hook could. Etched over the world's `backing`.
contract CreditingAsset is TestAsset {
    IPoolManager internal immutable manager;
    address internal immutable hook;

    constructor(IPoolManager poolManager, address credited) {
        manager = poolManager;
        hook = credited;
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /// The route under test unwraps: Core pays WETH and the debt is in ETH.
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        manager.sync(Currency.wrap(address(this)));
        _mint(address(manager), 1);
        manager.settleFor(hook);
        (bool ok,) = msg.sender.call{ value: amount }("");
        require(ok, "send");
    }
}

/// @dev A Core redemption that is reached through the wrap link (`docs/specs/hook-redeem-wrap.md`).
/// The debt is in ETH while Core pays WETH, so the extra wei Core returns must be given up
/// only once the WETH has been converted, not when it is settled.
contract ArbitrageRedeemWrapTest is WrapWorld {
    bytes32 internal poolId;
    ArbitrageLogic.Plan internal plan;

    /// What one fixed try did. `excess` is what Core returned beyond what was owed, so a try
    /// with `excess` above zero reached the `clear`.
    struct Outcome {
        bytes4 reason;
        uint256 profit;
        uint256 owed;
        uint256 excess;
        uint256 sold;
        uint256 gain;
    }

    /// NAV is about 2, so Core returns more than is owed on about half of all sizes.
    function _fund() internal {
        _declineSizing();
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
    }

    /// The plan of the first buy cycle the search tries at Core, taken from a real search.
    function _capture(PoolKey memory pool) internal {
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        hook.arb(_id(pool));
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.revertToState(snapshot);
        for (uint256 index; index < accesses.length; index++) {
            bytes memory data = accesses[index].data;
            if (accesses[index].account != address(hook)) continue;
            if (data.length < 4) continue;
            if (bytes4(data) != CyclePart.execute.selector) continue;
            bytes memory body = new bytes(data.length - 4);
            for (uint256 j; j < body.length; j++) {
                body[j] = data[j + 4];
            }
            (bytes32 found, ArbitrageLogic.Plan memory tried) =
                abi.decode(body, (bytes32, ArbitrageLogic.Plan));
            if (!tried.buying) continue;
            if (tried.venue != bytes32(0)) continue;
            poolId = found;
            plan = tried;
            return;
        }
        revert("no Core cycle through the wrap link");
    }

    function _usdRoute() internal {
        _szrThroughEthPool();
        _fund();
        _capture(usdPool);
    }

    /// One fixed try at `spend`, from the state it is called in, which it leaves changed.
    function _run(uint256 spend) internal returns (Outcome memory out) {
        ArbitrageLogic.Plan memory sized = plan;
        sized.spend = spend;
        uint256 supply = core.activeSupply();
        uint256 backed = core.backingAmount();
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        TryMeter meter = new TryMeter(manager, _probeInHook());
        (, out.reason) = meter.measure(1, address(szr), poolId, sized);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // WETH moves between the hook and the pool manager twice: Core's payment goes in,
        // and the debt, converted to ETH, comes out.
        uint256 received;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageLogic.Arbitraged.selector) {
                (, out.profit) = abi.decode(logs[index].data, (bool, uint256));
            }
            if (logs[index].emitter != address(backing)) continue;
            if (logs[index].topics[0] != TRANSFER) continue;
            address from = address(uint160(uint256(logs[index].topics[1])));
            address to = address(uint160(uint256(logs[index].topics[2])));
            uint256 amount = abi.decode(logs[index].data, (uint256));
            if (from == address(hook)) {
                if (to == address(manager)) received = amount;
            }
            if (from == address(manager)) {
                if (to == address(hook)) out.owed = amount;
            }
        }
        if (out.reason != bytes4(0)) return out;
        out.excess = received - out.owed;
        out.sold = FixedPointMathLib.fullMulDivUp(out.owed, supply, backed);
        out.gain = core.unreleasedSupply() - inventory;
    }

    /// The first size, in fortieths of the search's own, where Core returns owed + 1.
    function _pinned() internal returns (uint256 spend) {
        uint256 snapshot = vm.snapshotState();
        bytes4 last;
        for (uint256 step = 1; step <= 40; step++) {
            spend = plan.spend * step / 40;
            Outcome memory out = _run(spend);
            vm.revertToState(snapshot);
            if (out.reason != bytes4(0)) last = out.reason;
            if (out.reason == bytes4(0)) {
                if (out.excess == 1) return spend;
            }
        }
        revert(
            string.concat(
                "no size where Core returns one wei more; last revert ", vm.toString(last)
            )
        );
    }

    function _assertExact(Outcome memory out) internal {
        assertEq(out.reason, bytes4(0), "the try filled");
        assertGt(out.profit, 0, "profit");
        assertEq(out.gain, out.sold + out.profit, "the profit is what the cycle retired");
    }

    function _pinnedCycleSucceeds() internal {
        uint256 spend = _pinned();
        Outcome memory out = _run(spend);
        assertEq(out.excess, 1, "Core returned owed + 1 and the clear ran");
        _assertExact(out);
    }

    function testFixedPlanThroughWrapLinkSucceedsWhenCoreReturnsMore() public {
        _usdRoute();
        _pinnedCycleSucceeds();
    }

    /// Forty sizes at or under the search's own (larger ones are capped by its price limit).
    function _sweep() internal returns (uint256 cleared) {
        uint256 snapshot = vm.snapshotState();
        for (uint256 step = 1; step <= 40; step++) {
            Outcome memory out = _run(plan.spend * step / 40);
            _assertExact(out);
            if (out.excess != 0) cleared++;
            vm.revertToState(snapshot);
        }
        emit log_named_uint("sizes that reached the clear, of 40", cleared);
        assertGt(cleared, 0, "some sizes reached the clear");
    }

    function testSweepOfSizesNeverFailsToClear() public {
        _usdRoute();
        _sweep();
    }

    /// A credit the hook is left in WETH is not Core's excess, and must fail the cycle: only
    /// Core's excess is cleared, and the pool manager refuses a clear of less than the whole
    /// credit.
    function testSideCreditOfWethFailsTheCycle() public {
        _usdRoute();
        uint256 spend = _pinned();
        vm.etch(address(backing), address(new CreditingAsset(manager, address(hook))).code);
        Outcome memory out = _run(spend);
        assertEq(
            out.reason,
            IPoolManager.MustClearExactPositiveDelta.selector,
            "the credit is not cleared"
        );
    }
}
