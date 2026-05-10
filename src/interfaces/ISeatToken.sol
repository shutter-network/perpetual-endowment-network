// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Custom (non-ERC20) surface of the PEN seat token. Use IERC20 separately for standard ERC-20 calls.
interface ISeatToken {
    function supplyCap() external view returns (uint256);

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function isInactive(address account) external view returns (bool);

    function recordActivity(address account) external;
}
