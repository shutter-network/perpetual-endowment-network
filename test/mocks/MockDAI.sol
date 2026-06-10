// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockDAI is ERC20 {
    constructor() ERC20("Mock DAI", "DAI") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
