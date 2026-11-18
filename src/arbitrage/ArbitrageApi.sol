// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { EntryPart } from "./ArbitrageEntry.sol";
import { SearchPart } from "./ArbitrageSearch.sol";
import { SearchManyPart } from "./ArbitrageSearchMany.sol";
import { CyclePart } from "./ArbitrageCycle.sol";
import { SizerPart } from "./ArbitrageSizer.sol";
import { AdminPart } from "./ArbitrageAdmin.sol";

/// @notice The whole interface of the arbitrage hook, for code that talks to it: the scripts,
/// the vault and the tests. The hook's address answers all of it, through its own functions
/// and the modules it routes to. Nothing deploys this; it has no code of its own to run.
abstract contract ArbitrageApi is
    EntryPart,
    SearchPart,
    SearchManyPart,
    CyclePart,
    SizerPart,
    AdminPart
{ }
