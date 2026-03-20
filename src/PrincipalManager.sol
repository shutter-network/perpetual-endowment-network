// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract PrincipalManager is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant BONDING_ROLE = keccak256("BONDING_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");

    error ActiveVaultPositionExists(address vault, uint256 shares);
    error InsufficientAvailableYield(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error InvalidAdmin(address admin);
    error InvalidAmount();
    error InvalidAsset(address asset);
    error InvalidPrincipalVault(address vault);
    error InvalidPrincipalVaultAsset(address vault, address asset);
    error InvalidYieldReceiver(address receiver);
    error InvalidYieldVault(address vault);
    error InvalidYieldVaultAsset(address vault, address asset);
    error PrincipalInsolvent(uint256 accountedPrincipal, uint256 totalManagedAssets);
    error PrincipalUnderflow(uint256 accountedPrincipal, uint256 amount);

    IERC20 public immutable asset;
    IERC4626 public principalVault;
    IERC4626 public yieldVault;
    address public yieldVaultReceiver;
    uint256 public accountedPrincipal;
    uint256 public liquidReserveTarget;

    event AccountedPrincipalDecreased(uint256 previousPrincipal, uint256 newPrincipal, uint256 amount);
    event AccountedPrincipalIncreased(uint256 previousPrincipal, uint256 newPrincipal, uint256 amount);
    event LiquidReserveTargetUpdated(uint256 previousTarget, uint256 newTarget);
    event RefundPaid(address indexed receiver, uint256 amount);
    event PrincipalVaultDeposit(address indexed vault, uint256 assets, uint256 shares);
    event PrincipalVaultUpdated(address indexed previousVault, address indexed newVault);
    event PrincipalVaultWithdrawal(address indexed vault, uint256 assets, uint256 shares);
    event YieldTransferred(address indexed yieldVault, address indexed receiver, uint256 assets, uint256 shares);
    event YieldVaultUpdated(address indexed previousVault, address indexed newVault, address indexed receiver);

    constructor(IERC20 asset_, address admin_, address bonding_, address strategist_, uint256 liquidReserveTarget_) {
        if (address(asset_) == address(0)) revert InvalidAsset(address(asset_));
        if (admin_ == address(0)) revert InvalidAdmin(admin_);

        asset = asset_;
        liquidReserveTarget = liquidReserveTarget_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantOptionalRole(BONDING_ROLE, bonding_);
        _grantOptionalRole(STRATEGIST_ROLE, strategist_);
    }

    function recordPurchase(uint256 amount) external onlyRole(BONDING_ROLE) nonReentrant returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();

        uint256 previousPrincipal = accountedPrincipal;
        accountedPrincipal = previousPrincipal + amount;

        emit AccountedPrincipalIncreased(previousPrincipal, accountedPrincipal, amount);

        return _depositExcessToPrincipalVault();
    }

    function payRefund(address receiver, uint256 amount) external onlyRole(BONDING_ROLE) nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (amount > accountedPrincipal) revert PrincipalUnderflow(accountedPrincipal, amount);

        uint256 managedAssets = totalManagedAssets();
        if (managedAssets < accountedPrincipal) {
            revert PrincipalInsolvent(accountedPrincipal, managedAssets);
        }

        _ensureLiquidity(amount);
        asset.safeTransfer(receiver, amount);

        uint256 previousPrincipal = accountedPrincipal;
        accountedPrincipal = previousPrincipal - amount;

        emit AccountedPrincipalDecreased(previousPrincipal, accountedPrincipal, amount);
        emit RefundPaid(receiver, amount);
    }

    function setPrincipalVault(IERC4626 newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC4626 previousVault = principalVault;
        if (address(previousVault) != address(0) && address(previousVault) != address(newVault)) {
            uint256 currentShares = previousVault.balanceOf(address(this));
            if (currentShares != 0) revert ActiveVaultPositionExists(address(previousVault), currentShares);

            asset.forceApprove(address(previousVault), 0);
        }

        if (address(newVault) != address(0)) {
            if (newVault.asset() != address(asset)) {
                revert InvalidPrincipalVaultAsset(address(newVault), address(asset));
            }
            asset.forceApprove(address(newVault), type(uint256).max);
        }

        principalVault = newVault;
        emit PrincipalVaultUpdated(address(previousVault), address(newVault));
    }

    function setYieldVault(IERC4626 newYieldVault, address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC4626 previousVault = yieldVault;
        if (address(previousVault) != address(0) && address(previousVault) != address(newYieldVault)) {
            asset.forceApprove(address(previousVault), 0);
        }

        if (address(newYieldVault) != address(0)) {
            if (newYieldVault.asset() != address(asset)) {
                revert InvalidYieldVaultAsset(address(newYieldVault), address(asset));
            }
            if (receiver == address(0)) revert InvalidYieldReceiver(receiver);
            asset.forceApprove(address(newYieldVault), type(uint256).max);
        } else if (receiver != address(0)) {
            revert InvalidYieldVault(address(0));
        }

        yieldVault = newYieldVault;
        yieldVaultReceiver = receiver;
        emit YieldVaultUpdated(address(previousVault), address(newYieldVault), receiver);
    }

    function setLiquidReserveTarget(uint256 newTarget) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 previousTarget = liquidReserveTarget;
        liquidReserveTarget = newTarget;

        emit LiquidReserveTargetUpdated(previousTarget, newTarget);
    }

    function depositExcessToPrincipalVault() external onlyRole(STRATEGIST_ROLE) nonReentrant returns (uint256 shares) {
        return _depositExcessToPrincipalVault();
    }

    function transferYieldToVault(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (amount == 0) revert InvalidAmount();

        IERC4626 currentYieldVault = yieldVault;
        if (address(currentYieldVault) == address(0)) revert InvalidYieldVault(address(0));
        address receiver = yieldVaultReceiver;
        if (receiver == address(0)) revert InvalidYieldReceiver(receiver);

        uint256 available = availableYield();
        if (amount > available) revert InsufficientAvailableYield(amount, available);

        _ensureLiquidity(amount);
        uint256 shares = currentYieldVault.deposit(amount, receiver);

        emit YieldTransferred(address(currentYieldVault), receiver, amount, shares);
    }

    function depositToPrincipalVault(uint256 assets)
        external
        onlyRole(STRATEGIST_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        if (assets > excessLiquidAssets()) {
            revert InsufficientLiquidity(assets, excessLiquidAssets());
        }

        shares = _depositToPrincipalVault(assets);
    }

    function withdrawFromPrincipalVault(uint256 assets)
        external
        onlyRole(STRATEGIST_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        IERC4626 currentVault = principalVault;
        if (address(currentVault) == address(0)) revert InvalidPrincipalVault(address(0));

        shares = currentVault.withdraw(assets, address(this), address(this));
        emit PrincipalVaultWithdrawal(address(currentVault), assets, shares);
    }

    function liquidAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function deployedAssets() public view returns (uint256) {
        IERC4626 currentVault = principalVault;
        if (address(currentVault) == address(0)) {
            return 0;
        }

        uint256 shares = currentVault.balanceOf(address(this));
        if (shares == 0) {
            return 0;
        }

        return currentVault.convertToAssets(shares);
    }

    function totalManagedAssets() public view returns (uint256) {
        return liquidAssets() + deployedAssets();
    }

    function availableYield() public view returns (uint256) {
        uint256 totalAssets = totalManagedAssets();
        if (totalAssets <= accountedPrincipal) {
            return 0;
        }

        return totalAssets - accountedPrincipal;
    }

    function excessLiquidAssets() public view returns (uint256) {
        uint256 liquid = liquidAssets();
        if (liquid <= liquidReserveTarget) {
            return 0;
        }

        return liquid - liquidReserveTarget;
    }

    function _depositToPrincipalVault(uint256 assets) internal returns (uint256 shares) {
        IERC4626 currentVault = principalVault;
        if (address(currentVault) == address(0)) revert InvalidPrincipalVault(address(0));

        shares = currentVault.deposit(assets, address(this));
        emit PrincipalVaultDeposit(address(currentVault), assets, shares);
    }

    function _depositExcessToPrincipalVault() internal returns (uint256 shares) {
        IERC4626 currentVault = principalVault;
        if (address(currentVault) == address(0)) {
            return 0;
        }

        uint256 assets = excessLiquidAssets();
        if (assets == 0) {
            return 0;
        }

        shares = _depositToPrincipalVault(assets);
    }

    function _ensureLiquidity(uint256 amount) internal {
        uint256 liquid = liquidAssets();
        if (liquid >= amount) {
            return;
        }

        IERC4626 currentVault = principalVault;
        if (address(currentVault) == address(0)) revert InsufficientLiquidity(amount, liquid);

        uint256 shortfall = amount - liquid;
        uint256 maxAssets = currentVault.maxWithdraw(address(this));
        if (maxAssets < shortfall) {
            revert InsufficientLiquidity(amount, liquid + maxAssets);
        }

        uint256 shares = currentVault.withdraw(shortfall, address(this), address(this));
        emit PrincipalVaultWithdrawal(address(currentVault), shortfall, shares);
    }

    function _grantOptionalRole(bytes32 role, address account) internal {
        if (account == address(0)) {
            return;
        }

        _grantRole(role, account);
    }
}
