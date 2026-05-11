// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockEnzymeVault {
    uint256 private _nav;

    constructor(uint256 initialNav) {
        _nav = initialNav;
    }

    function getGav() external view returns (uint256) {
        return _nav;
    }

    function setGav(uint256 newNav) external {
        _nav = newNav;
    }
}
