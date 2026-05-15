// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAToken is ERC20 {
    uint8 private immutable _decimalsValue;
    address public minter;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsValue = decimals_;
        minter = msg.sender;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "MockAToken: only minter");
        _;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }

    function setMinter(address newMinter) external onlyMinter {
        require(newMinter != address(0), "MockAToken: zero minter");
        minter = newMinter;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}
