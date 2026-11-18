// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev The part of Metric's factory this repo calls.
interface IMetricFactory {
    function isPool(address pool) external view returns (bool);
}
