// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IPrincipalManager {
    function asset() external view returns (IERC20);

    function recordPurchase(uint256 amount) external returns (uint256 shares);

    function payRefund(address receiver, uint256 amount) external;

    function totalManagedAssets() external view returns (uint256);
}
