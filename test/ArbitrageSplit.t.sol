// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { ArbitrageLogic, IArbitrageSelf } from "../src/arbitrage/ArbitrageLogic.sol";
import { EntryPart } from "../src/arbitrage/ArbitrageEntry.sol";
import { SearchPart } from "../src/arbitrage/ArbitrageSearch.sol";
import { SearchManyPart } from "../src/arbitrage/ArbitrageSearchMany.sol";
import { CyclePart } from "../src/arbitrage/ArbitrageCycle.sol";
import { SizerPart } from "../src/arbitrage/ArbitrageSizer.sol";
import { AdminPart } from "../src/arbitrage/ArbitrageAdmin.sol";

/// @dev Only to reach `_hopped`, the cap a self-call is given for its hop to a module.
contract Hopper is ArbitrageLogic {
    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }

    function hopped(uint256 gas) external pure returns (uint256) {
        return _hopped(gas);
    }
}

/// @dev The hook is split over modules (`docs/specs/hook-split.md`): every piece fits the
/// size limit, shares one storage layout, is reached by the right selector, and is refused
/// when it was built for another Liquidity.
contract ArbitrageSplitTest is ArbitrageWorld {
    uint256 internal constant EIP_170 = 24_576;

    ArbitrageHook internal split;

    function setUp() public override {
        super.setUp();
        split = ArbitrageHook(payable(address(hook)));
    }

    // ----- size -----

    function testEveryProductionContractFitsTheCodeLimit() public {
        string[15] memory names = [
            "ArbitrageHook",
            "ArbitrageSearch",
            "ArbitrageSearchMany",
            "ArbitrageCycle",
            "ArbitrageSizer",
            "ArbitrageAdmin",
            "ArbitrageVault",
            "MetricVenueHook",
            "MetricArbitrageExtension",
            "Szr",
            "SzrCore",
            "SzrEconomics",
            "SzrMigration",
            "FeeCollector",
            "Liquidity"
        ];
        for (uint256 index; index < names.length; index++) {
            string memory name = names[index];
            uint256 size = vm.getDeployedCode(string.concat(name, ".sol:", name)).length;
            assertGt(size, 0, name);
            assertLe(size, EIP_170, name);
        }
    }

    // ----- storage layout -----

    /// Every piece reads the slots the hook writes: each one's code, put in the hook's place,
    /// reads the same values from the hook's storage. Only `ArbitrageLogic` declares state, so
    /// this holds for the whole layout; these four are spread across it.
    function testEveryPieceReadsTheHooksStorage() public {
        uint256 opened = hook.openMarket(address(this));
        assertEq(opened, 2, "a second market");
        bytes memory real = address(hook).code;
        // Read before the code goes: it comes from an immutable, which a piece's artifact has
        // as zero.
        address szrToken = hook.token();
        string[7] memory pieces = [
            "ArbitrageSearch.sol:ArbitrageSearch",
            "ArbitrageSearchMany.sol:ArbitrageSearchMany",
            "ArbitrageCycle.sol:ArbitrageCycle",
            "ArbitrageSizer.sol:ArbitrageSizer",
            "ArbitrageAdmin.sol:ArbitrageAdmin",
            "ArbitrageHook.sol:ArbitrageHook",
            "ArbitrageProbe.sol:ArbitrageProbe"
        ];
        for (uint256 index; index < pieces.length; index++) {
            vm.etch(address(hook), vm.getDeployedCode(pieces[index]));
            assertEq(hook.marketCount(), 2, pieces[index]);
            assertEq(hook.shareRecipient(address(backing)), address(core), pieces[index]);
            assertEq(hook.minimumProfit(1, szrToken), 10e18, pieces[index]);
            assertTrue(hook.tracked(1, _id(mainPool)), pieces[index]);
        }
        vm.etch(address(hook), real);
    }

    // ----- routing -----

    function _stub(address module, uint8 tag) internal {
        // Code that returns its tag as one word, whatever it is called with.
        vm.etch(module, abi.encodePacked(hex"60", bytes1(tag), hex"5f5260205ff3"));
    }

    function _tag(bytes4 selector) internal returns (uint256) {
        (bool ok, bytes memory data) =
            address(hook).call(abi.encodePacked(selector, new bytes(256)));
        assertTrue(ok, "the call went through");
        return abi.decode(data, (uint256));
    }

    function testEachMovedSelectorReachesItsModule() public {
        _stub(split.searchModule(), 1);
        _stub(split.manyModule(), 2);
        _stub(split.cycleModule(), 3);
        _stub(split.sizerModule(), 4);
        _stub(split.adminModule(), 5);
        assertEq(_tag(SearchPart.search.selector), 1, "search");
        assertEq(_tag(SearchPart.arb.selector), 1, "arb");
        assertEq(_tag(SearchPart.sweep.selector), 1, "sweep");
        assertEq(_tag(SearchPart.unlockCallback.selector), 1, "unlockCallback");
        assertEq(_tag(SearchPart.askFrame.selector), 1, "askFrame");
        assertEq(_tag(SearchManyPart.searchMany.selector), 2, "searchMany");
        assertEq(_tag(CyclePart.execute.selector), 3, "execute");
        assertEq(_tag(SizerPart.size.selector), 4, "size");
        assertEq(_tag(AdminPart.setLimits.selector), 5, "setLimits");
        assertEq(_tag(AdminPart.market.selector), 5, "market");
        assertEq(_tag(AdminPart.gasForSwap.selector), 5, "gasForSwap");
        assertEq(_tag(AdminPart.minimumGasLimit.selector), 5, "minimumGasLimit");
        // Not one of the hook's own functions, so it goes where everything else goes.
        assertEq(_tag(bytes4(0xdeadbeef)), 5, "unknown selector, to Admin");
    }

    function testTheHooksOwnFunctionsAreNotRouted() public {
        _stub(split.searchModule(), 1);
        _stub(split.manyModule(), 2);
        _stub(split.cycleModule(), 3);
        _stub(split.sizerModule(), 4);
        _stub(split.adminModule(), 5);
        // `venueSearch` is the hook's own: a caller that is no wrapper is refused by it.
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.venueSearch(_id(usdPool), true, address(this));
        vm.expectRevert(ArbitrageLogic.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            usdPool,
            IPoolManager.SwapParams(true, 0, 0),
            BalanceDelta.wrap(0),
            ""
        );
    }

    function testAnUnknownSelectorReverts() public {
        (bool ok, bytes memory data) = address(hook).call(abi.encodePacked(bytes4(0xdeadbeef)));
        assertFalse(ok, "reverted");
        assertEq(data.length, 0, "with nothing to say");
        (ok,) = address(hook).call(abi.encodePacked(bytes4(0xdeadbeef), new bytes(64)));
        assertFalse(ok, "and with arguments");
    }

    function testRevertsAreBubbledFromTheModuleUnchanged() public {
        vm.expectRevert(ArbitrageLogic.NotSelf.selector);
        hook.askFrame(address(this), bytes32(0));
        address szrToken = hook.token();
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        vm.prank(alice);
        hook.setLimits(1, szrToken, 1, 1, 1.0001e18);
    }

    // ----- the modules alone -----

    function _modules() internal view returns (address[5] memory list) {
        list = [
            split.searchModule(),
            split.manyModule(),
            split.cycleModule(),
            split.sizerModule(),
            split.adminModule()
        ];
    }

    function testEachSelfOnlyFunctionRefusesAnOutsideCallerInItsModule() public {
        ArbitrageLogic.Plan memory plan;
        // The addresses are read first: any call before the revert is expected would use it up.
        SearchPart searching = SearchPart(split.searchModule());
        SearchManyPart many = SearchManyPart(split.manyModule());
        CyclePart cycle = CyclePart(split.cycleModule());
        SizerPart sizer = SizerPart(split.sizerModule());
        vm.expectRevert(ArbitrageLogic.NotSelf.selector);
        searching.askFrame(address(this), bytes32(0));
        vm.expectRevert(ArbitrageLogic.NotSelf.selector);
        searching.search(bytes32(0), 1, address(0), address(0), true, true, address(0));
        vm.expectRevert(ArbitrageLogic.NotSelf.selector);
        many.searchMany(
            new bytes32[](0), 1, new address[](0), new address[](0), true, true, address(0)
        );
        vm.expectRevert(ArbitrageLogic.NotSelf.selector);
        cycle.execute(bytes32(0), plan);
        vm.expectRevert(ArbitrageLogic.NotSelf.selector);
        sizer.size(bytes32(0), plan);
    }

    function testAModuleHasStorageOfItsOwn() public view {
        // The hook set these up for itself; a module, which has no part in that, has none.
        assertEq(hook.shareRecipient(address(backing)), address(core), "hook");
        assertEq(AdminPart(split.adminModule()).shareRecipient(address(backing)), address(0));
        assertEq(AdminPart(split.adminModule()).minimumProfit(1, hook.token()), 0);
        assertFalse(AdminPart(split.adminModule()).tracked(1, _id(mainPool)));
    }

    // ----- construction -----

    function _deployHook(
        address search,
        address many,
        address cycle,
        address sizer,
        address admin
    ) internal returns (bool ok, bytes memory data) {
        address at = address(uint160(0xA4B7 << 24 | 1 << 7 | 1 << 6));
        bytes memory args = abi.encode(locker, search, many, cycle, sizer, admin);
        vm.etch(at, abi.encodePacked(vm.getCode("ArbitrageHook.sol:ArbitrageHook"), args));
        (ok, data) = at.call("");
    }

    function testTheHookAcceptsModulesBuiltOnItsLiquidity() public {
        address[5] memory list = _modules();
        (bool ok,) = _deployHook(list[0], list[1], list[2], list[3], list[4]);
        assertTrue(ok, "deployed");
    }

    function testTheHookRefusesAModuleBuiltOnAnotherLiquidity() public {
        address other = address(new Liquidity(core, jar, manager, address(this)));
        for (uint256 index; index < 5; index++) {
            address[5] memory list = _modules();
            list[index] = _moduleFor(other);
            (bool ok, bytes memory data) =
                _deployHook(list[0], list[1], list[2], list[3], list[4]);
            assertFalse(ok, "refused");
            assertEq(bytes4(data), ArbitrageHook.ModuleMismatch.selector, "mismatch");
        }
    }

    function _moduleFor(address other) internal returns (address at) {
        at = address(uint160(uint256(keccak256(abi.encode("other", other)))));
        deployCodeTo("ArbitrageAdmin.sol:ArbitrageAdmin", abi.encode(other), at);
    }

    function testTheHookStillNeedsItsPermissionBits() public {
        address[5] memory list = _modules();
        address at = address(uint160(0xA4B8 << 24 | 1 << 7));
        bytes memory args = abi.encode(locker, list[0], list[1], list[2], list[3], list[4]);
        vm.etch(at, abi.encodePacked(vm.getCode("ArbitrageHook.sol:ArbitrageHook"), args));
        (bool ok, bytes memory data) = at.call("");
        assertFalse(ok, "refused");
        assertEq(bytes4(data), ArbitrageLogic.InvalidHookAddress.selector, "wrong bits");
    }

    // ----- the hop -----

    /// The hook's `fallback` costs gas before the module runs, and keeps back a 64th. A cap
    /// raised by `_hopped` must still reach the module whole, cold, for every self-call.
    function testTheModuleGetsAtLeastTheCapThroughTheHop() public {
        Hopper hopper = new Hopper(split.liquidity());
        // Stops after recording the gas it was entered with, in a slot the hook never uses.
        bytes memory stub =
            hex"5a7f00000000000000000000000000000000000000000000000000000000000000ee5500";
        address[4] memory modules = [
            split.searchModule(), split.manyModule(), split.cycleModule(), split.sizerModule()
        ];
        for (uint256 index; index < 4; index++) {
            vm.etch(modules[index], stub);
        }
        ArbitrageLogic.Plan memory plan;
        bytes32[] memory centres = new bytes32[](8);
        address[] memory bases = new address[](8);
        bytes[5] memory calls = [
            abi.encodeCall(
                IArbitrageSelf.search,
                (bytes32(0), 1, address(0), address(0), true, true, alice)
            ),
            abi.encodeCall(
                IArbitrageSelf.searchMany, (centres, 1, bases, bases, true, true, alice)
            ),
            abi.encodeCall(IArbitrageSelf.execute, (bytes32(0), plan)),
            abi.encodeCall(IArbitrageSelf.size, (bytes32(0), plan)),
            abi.encodeCall(IArbitrageSelf.askFrame, (address(0), bytes32(0)))
        ];
        address[5] memory targets = [modules[0], modules[1], modules[2], modules[3], modules[0]];
        uint256[5] memory caps = [uint256(1_500_000), 1_500_000, 1_500_000, 400_000, 300_000];
        for (uint256 index; index < 5; index++) {
            vm.cool(address(hook));
            vm.cool(targets[index]);
            uint256 given = hopper.hopped(caps[index]);
            (bool ok,) = address(hook).call{ gas: given }(calls[index]);
            assertTrue(ok, "reached");
            uint256 seen = uint256(vm.load(address(hook), bytes32(uint256(0xee))));
            assertGe(seen, caps[index], "the module got the cap");
            vm.store(address(hook), bytes32(uint256(0xee)), bytes32(0));
        }
    }
}
