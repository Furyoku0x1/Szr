// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ISzrLiquidity {
    function core() external view returns (address);
    function feeJar() external view returns (address);
    function manager() external view returns (address);
    function onLaunch() external;
    function recordFunding(uint256 amount) external;
}

interface ISzrFeeCollector {
    function core() external view returns (address);
}

interface ISzrMigration {
    function core() external view returns (address);
}
