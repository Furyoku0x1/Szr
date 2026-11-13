// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ContinuousAuction } from "../src/ContinuousAuction.sol";
import { ContinuousAuctionV1 } from "./utils/ContinuousAuctionV1.sol";

/// @dev External wrapper so a revert in the frozen original can be caught and skipped.
contract OriginalCurve {
    using ContinuousAuctionV1 for ContinuousAuctionV1.State;

    function create(uint256 depth, uint256 price, uint256 floor)
        external
        pure
        returns (ContinuousAuctionV1.State memory)
    {
        return ContinuousAuctionV1.create(depth, price, floor);
    }

    function project(ContinuousAuctionV1.State memory state, uint256 elapsed, uint256 depth)
        external
        pure
        returns (ContinuousAuctionV1.State memory)
    {
        state.project(elapsed, depth);
        return state;
    }

    function buy(ContinuousAuctionV1.State memory state, uint256 quantity)
        external
        pure
        returns (ContinuousAuctionV1.State memory, uint256 payment)
    {
        payment = state.buy(quantity);
        return (state, payment);
    }

    function price(ContinuousAuctionV1.State memory state) external pure returns (uint256) {
        return state.price();
    }
}

/// @notice The live pricing library must match the audited original bit for bit wherever the
/// original works, and match an unbounded-integer reference above the original's range.
contract ContinuousAuctionEquivalenceTest is Test {
    using ContinuousAuction for ContinuousAuction.State;

    uint256 internal constant DURATION = 2 days;
    uint256 internal constant FULL_DEPTH = 1_000_200_000e18; // total supply plus sale buffer
    OriginalCurve internal original = new OriginalCurve();
    uint256 internal entropy;
    uint256[4] internal compared; // steps of each kind that ran in both libraries and matched

    /// forge-config: default.fuzz.runs = 5000
    function testFuzzMatchesTheOriginalStepByStep(uint256 seed) public {
        _run(seed);
    }

    /// The fuzz above is only evidence if its sequences really run: most steps must complete,
    /// and every kind of step must be compared many times.
    function testEquivalenceSequencesAreNotVacuous() public {
        for (uint256 seed; seed < 400; seed++) {
            _run(uint256(keccak256(abi.encode("coverage", seed))));
        }
        uint256 total = compared[0] + compared[1] + compared[2] + compared[3];
        assertGt(total, 400 * 12 * 7 / 10);
        for (uint256 kind; kind < 4; kind++) {
            assertGt(compared[kind], 400);
        }
    }

    function _run(uint256 seed) internal {
        entropy = seed;
        uint256 depth = _depth();
        // Halve the original's price ceiling a random number of times, so some sequences sit
        // at the edge of its range and most have room for depth to grow.
        uint256 cap = ((type(uint256).max / DURATION) / (depth * depth)) >> (_next() % 80);
        if (cap < 2) cap = 2;
        uint256 opening = bound(_next(), 2, cap);
        uint256 floor = bound(_next(), 1, opening - 1);
        ContinuousAuctionV1.State memory old = original.create(depth, opening, floor);
        ContinuousAuction.State memory live = ContinuousAuction.create(depth, opening, floor);
        _same(live, old);
        for (uint256 step; step < 12; step++) {
            uint256 kind = _next() % 4;
            if (kind == 0) {
                uint256 elapsed = _elapsed();
                try original.project(old, elapsed, old.depth) returns (
                    ContinuousAuctionV1.State memory next
                ) {
                    old = next;
                } catch {
                    return;
                }
                live.project(elapsed, live.depth);
            } else if (kind == 1) {
                uint256 elapsed = _elapsed();
                uint256 target = _depth();
                try original.project(old, elapsed, target) returns (
                    ContinuousAuctionV1.State memory next
                ) {
                    old = next;
                } catch {
                    return;
                }
                live.project(elapsed, target);
            } else if (kind == 2) {
                if (old.depth < 2) continue;
                uint256 quantity = _quantity(old.depth);
                uint256 expected;
                try original.buy(old, quantity) returns (
                    ContinuousAuctionV1.State memory next, uint256 payment
                ) {
                    old = next;
                    expected = payment;
                } catch {
                    return;
                }
                assertEq(live.buy(quantity), expected);
            } else {
                // Core raises the floor and clears the decay when the price has fallen below it.
                uint256 current = original.price(old);
                uint256 raised = bound(_next(), old.floorWad, current * 2);
                if (current >= raised) continue;
                old.floorWad = raised;
                old.excessTime = 0;
                old.decayMass = 0;
                live.floorWad = raised;
                live.excess = 0;
                live.decayMass = 0; // deliberately leaves `deficit` stale
                try original.price(old) returns (uint256) { }
                catch {
                    return;
                }
            }
            _same(live, old);
            compared[kind] += 1;
        }
    }

    /// Above the original's range only an unbounded-integer reference can say what is right.
    /// These vectors come from test/fixtures/continuous_auction_reference.py and are exact.
    function testMatchesTheUnboundedReferenceAboveTheOriginalRange() public view {
        string memory data = vm.readFile("test/fixtures/continuous-auction-extended.json");
        for (uint256 index; index < 60; index++) {
            _checkExtended(data, string.concat("[", vm.toString(index), "]"));
        }
    }

    /// Closes the triangle: the same unbounded reference agrees exactly with the frozen
    /// original inside the original's range, so it is a faithful copy of the audited maths.
    function testUnboundedReferenceMatchesTheOriginalInsideItsRange() public view {
        string memory data = vm.readFile("test/fixtures/continuous-auction-inrange.json");
        for (uint256 index; index < 60; index++) {
            _checkInRange(data, string.concat("[", vm.toString(index), "]"));
        }
    }

    function _checkInRange(string memory data, string memory key) internal view {
        ContinuousAuctionV1.State memory old = original.create(
            vm.parseJsonUint(data, string.concat(key, ".depth")),
            vm.parseJsonUint(data, string.concat(key, ".opening")),
            vm.parseJsonUint(data, string.concat(key, ".floor"))
        );
        uint256[] memory kind = vm.parseJsonUintArray(data, string.concat(key, ".kind"));
        uint256[] memory first = vm.parseJsonUintArray(data, string.concat(key, ".first"));
        uint256[] memory second = vm.parseJsonUintArray(data, string.concat(key, ".second"));
        uint256[] memory payment = vm.parseJsonUintArray(data, string.concat(key, ".payment"));
        uint256[] memory price = vm.parseJsonUintArray(data, string.concat(key, ".price"));
        uint256[] memory mass = vm.parseJsonUintArray(data, string.concat(key, ".mass"));
        uint256[] memory time = vm.parseJsonUintArray(data, string.concat(key, ".time"));
        for (uint256 step; step < kind.length; step++) {
            if (kind[step] == 2) {
                uint256 paid;
                (old, paid) = original.buy(old, first[step]);
                assertEq(paid, payment[step]);
            } else {
                old = original.project(old, first[step], second[step]);
            }
            assertEq(original.price(old), price[step]);
            assertEq(old.excessTime, time[step]);
            assertEq(old.decayMass, mass[step]);
        }
    }

    function _checkExtended(string memory data, string memory key) internal pure {
        uint256 depth = vm.parseJsonUint(data, string.concat(key, ".depth"));
        uint256 opening = vm.parseJsonUint(data, string.concat(key, ".opening"));
        // Every vector starts where the original library reverts.
        assertGt(opening, (type(uint256).max / DURATION) / (depth * depth));
        ContinuousAuction.State memory live = ContinuousAuction.create(
            depth, opening, vm.parseJsonUint(data, string.concat(key, ".floor"))
        );
        uint256[] memory kind = vm.parseJsonUintArray(data, string.concat(key, ".kind"));
        uint256[] memory first = vm.parseJsonUintArray(data, string.concat(key, ".first"));
        uint256[] memory second = vm.parseJsonUintArray(data, string.concat(key, ".second"));
        uint256[] memory payment = vm.parseJsonUintArray(data, string.concat(key, ".payment"));
        uint256[] memory price = vm.parseJsonUintArray(data, string.concat(key, ".price"));
        uint256[] memory excess = vm.parseJsonUintArray(data, string.concat(key, ".excess"));
        uint256[] memory deficit = vm.parseJsonUintArray(data, string.concat(key, ".deficit"));
        uint256[] memory mass = vm.parseJsonUintArray(data, string.concat(key, ".mass"));
        for (uint256 step; step < kind.length; step++) {
            if (kind[step] == 2) assertEq(live.buy(first[step]), payment[step]);
            else live.project(first[step], second[step]);
            assertEq(live.price(), price[step]);
            assertEq(live.excess, excess[step]);
            assertEq(live.deficit, deficit[step]);
            assertEq(live.decayMass, mass[step]);
            assertLe(live.excess, live.decayMass);
        }
    }

    function _same(ContinuousAuction.State memory live, ContinuousAuctionV1.State memory old)
        internal
        view
    {
        assertEq(live.depth, old.depth);
        assertEq(live.floorWad, old.floorWad);
        assertEq(live.decayMass, old.decayMass);
        // The exact decaying quantity is `excess * DURATION - deficit`.
        uint256 excess = old.excessTime / DURATION;
        uint256 deficit;
        if (old.excessTime % DURATION != 0) {
            excess += 1;
            deficit = DURATION - old.excessTime % DURATION;
        }
        assertEq(live.excess, excess);
        if (live.excess != 0) assertEq(live.deficit, deficit);
        assertLe(live.excess, live.decayMass); // remaining time never exceeds DURATION
        assertEq(live.price(), original.price(old));
    }

    function _next() internal returns (uint256) {
        entropy = uint256(keccak256(abi.encode(entropy)));
        return entropy;
    }

    /// Log-uniform between one token and the full supply, so ratios reach buffer-to-supply.
    function _depth() internal returns (uint256) {
        uint256 scale = 10 ** bound(_next(), 18, 27);
        return bound(_next(), scale, scale * 10 > FULL_DEPTH ? FULL_DEPTH : scale * 10);
    }

    function _elapsed() internal returns (uint256) {
        uint256 shape = _next() % 5;
        if (shape == 0) return 0;
        if (shape == 1) return bound(_next(), 1, 600);
        if (shape == 2) return bound(_next(), 1, DURATION - 1);
        if (shape == 3) return bound(_next(), DURATION - 2, DURATION + 2);
        return bound(_next(), DURATION, 100 * 365 days);
    }

    function _quantity(uint256 depth) internal returns (uint256) {
        uint256 shape = _next() % 4;
        if (shape == 0) return bound(_next(), 1, 1000);
        if (shape == 1) return bound(_next(), 1, depth / 2 + 1);
        if (shape == 2) return bound(_next(), depth - depth / 1000 - 1, depth - 1);
        return bound(_next(), 1, depth - 1);
    }
}
