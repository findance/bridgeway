// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockBGWToken is ERC20 {
    uint256 public totalBurned;

    constructor() ERC20("Mock Bridgeway", "BGW") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        totalBurned += amount;
    }
}
