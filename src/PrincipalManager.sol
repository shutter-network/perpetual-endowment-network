// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IPrincipalManager} from "./interfaces/IPrincipalManager.sol";

contract PrincipalManager is IPrincipalManager, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant BONDING_ROLE = keccak256("BONDING_ROLE");

    error InsufficientLiquidity(uint256 requested, uint256 available);
    error InvalidAdmin(address admin);
    error InvalidAmount();
    error InvalidAsset(address asset);
    error InvalidFundingParams();
    error InvalidPrincipalVault(address vault);
    error InvalidPrincipalVaultAsset(address vault, address asset);
    error InvalidVault(address vault);
    error InvalidVaultAsset(address vault, address asset);
    error InvalidReceiver(address receiver);
    error PrincipalUnderflow(uint256 accountedPrincipal, uint256 amount);

    IERC20 public immutable override asset;
    IERC4626 public principalVault;
    IERC4626[] public previousPrincipalVaults;
    mapping(address vault => bool) private _isPreviousPrincipalVault;
    uint256 public accountedPrincipal;
    uint256 public liquidReserveTarget;

    event AccountedPrincipalDecreased(uint256 previousPrincipal, uint256 newPrincipal, uint256 amount);
    event AccountedPrincipalIncreased(uint256 previousPrincipal, uint256 newPrincipal, uint256 amount);
    event LiquidReserveTargetUpdated(uint256 previousTarget, uint256 newTarget);
    event FundingExecuted(address[] indexed recipients, uint256[] amounts);
    event RefundPaid(address indexed receiver, uint256 amount);
    event PrincipalVaultDeposit(address indexed vault, uint256 assets, uint256 shares);
    event PrincipalVaultUpdated(address indexed previousVault, address indexed newVault);
    event PrincipalVaultWithdrawal(address indexed vault, address indexed receiver, uint256 assets, uint256 shares);
    event VaultWithdrawal(address indexed vault, address indexed receiver, uint256 assets, uint256 shares);
    event Withdrawn(address indexed token, address indexed receiver, uint256 amount);

    constructor(
        IERC20 asset_,
        address admin_,
        address bonding_,
        uint256 liquidReserveTarget_,
        IERC4626 initialPrincipalVault_
    ) {
        if (address(asset_) == address(0)) revert InvalidAsset(address(asset_));
        if (admin_ == address(0)) revert InvalidAdmin(admin_);

        asset = asset_;
        liquidReserveTarget = liquidReserveTarget_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantOptionalRole(BONDING_ROLE, bonding_);

        _setPrincipalVault(initialPrincipalVault_);
    }

    function recordPurchase(uint256 amount)
        external
        override
        onlyRole(BONDING_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (amount == 0) revert InvalidAmount();

        uint256 previousPrincipal = accountedPrincipal;
        accountedPrincipal = previousPrincipal + amount;

        emit AccountedPrincipalIncreased(previousPrincipal, accountedPrincipal, amount);

        return _depositExcessToPrincipalVault();
    }

    function payRefund(address receiver, uint256 amount)
        external
        override
        onlyRole(BONDING_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        if (amount > accountedPrincipal) revert PrincipalUnderflow(accountedPrincipal, amount);

        _ensureLiquidity(amount);

        uint256 previousPrincipal = accountedPrincipal;
        accountedPrincipal = previousPrincipal - amount;

        asset.safeTransfer(receiver, amount);

        emit AccountedPrincipalDecreased(previousPrincipal, accountedPrincipal, amount);
        emit RefundPaid(receiver, amount);
    }

    function setPrincipalVault(IERC4626 newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPrincipalVault(newVault);
    }

    function _setPrincipalVault(IERC4626 newVault) internal {
        IERC4626 previousVault = principalVault;
        if (address(previousVault) != address(0) && address(previousVault) != address(newVault)) {
            asset.forceApprove(address(previousVault), 0);
            _trackPreviousVault(previousVault);
        }

        if (address(newVault) != address(0)) {
            if (newVault.asset() != address(asset)) {
                revert InvalidPrincipalVaultAsset(address(newVault), address(asset));
            }
        }

        principalVault = newVault;
        emit PrincipalVaultUpdated(address(previousVault), address(newVault));
    }

    function previousPrincipalVaultCount() external view returns (uint256) {
        return previousPrincipalVaults.length;
    }

    function isPrincipalVaultSet() public view returns (bool) {
        return address(principalVault) != address(0);
    }

    function setLiquidReserveTarget(uint256 newTarget) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 previousTarget = liquidReserveTarget;
        liquidReserveTarget = newTarget;

        emit LiquidReserveTargetUpdated(previousTarget, newTarget);
    }

    function depositExcessToPrincipalVault()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        return _depositExcessToPrincipalVault();
    }

    /// @notice Distribute funds to multiple recipients (governance-controlled).
    /// @dev PEN keeps this as a single-call “batch payout” primitive because it is materially cheaper
    ///      than executing 1 + N separate Safe/Azorius transactions (withdraw to Safe + N ERC20 transfers),
    ///      especially as N grows.
    ///
    ///      This function intentionally does NOT decrease `accountedPrincipal`.
    ///      `accountedPrincipal` represents the principal obligation created when seats are sold (used for refunds).
    ///      Funding payouts are intended to be paid from yield / excess assets not by reducing the refund obligation.
    function executeFunding(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 distributedAmount)
    {
        uint256 length = recipients.length;
        if (length == 0 || length != amounts.length) revert InvalidFundingParams();

        for (uint256 i; i < length; ++i) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];
            if (recipient == address(0)) revert InvalidReceiver(recipient);
            if (amount == 0) revert InvalidAmount();
            distributedAmount += amount;
        }

        _ensureLiquidity(distributedAmount);

        for (uint256 i; i < length; ++i) {
            asset.safeTransfer(recipients[i], amounts[i]);
        }

        emit FundingExecuted(recipients, amounts);
    }

    function depositToPrincipalVault(uint256 assets)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        if (assets > excessLiquidAssets()) {
            revert InsufficientLiquidity(assets, excessLiquidAssets());
        }

        shares = _depositToPrincipalVault(assets);
    }

    function withdrawFromPrincipalVault(uint256 assets, address receiver)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        IERC4626 currentVault = principalVault;
        if (address(currentVault) == address(0)) revert InvalidPrincipalVault(address(0));

        address resolvedReceiver;
        (shares, resolvedReceiver) = _withdrawFromVault(currentVault, assets, receiver);

        emit PrincipalVaultWithdrawal(address(currentVault), resolvedReceiver, assets, shares);
    }

    function withdrawFromVault(IERC4626 vault, uint256 assets, address receiver)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 shares)
    {
        if (address(vault) == address(0)) revert InvalidVault(address(0));
        if (vault.asset() != address(asset)) {
            revert InvalidVaultAsset(address(vault), address(asset));
        }

        address resolvedReceiver;
        (shares, resolvedReceiver) = _withdrawFromVault(vault, assets, receiver);

        emit VaultWithdrawal(address(vault), resolvedReceiver, assets, shares);
    }

    /// @notice Pause `recordPurchase` and `payRefund`. Intended for winding the system down
    ///         before a PEN→PEN migration (e.g. moving treasury to a freshly-deployed PEN
    ///         with different asset / parameters). See `docs/pen-migration.md`.
    /// @dev Does NOT freeze admin operations: `withdraw`, `executeFunding`, vault management,
    ///      and role administration continue to work. Reclaim is gated separately on
    ///      `BondingTranche` and also blocked while paused.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function paused() public view override(IPrincipalManager, Pausable) returns (bool) {
        return Pausable.paused();
    }

    /// @notice Admin-controlled withdrawal of any ERC20 balance held by this contract.
    /// @dev Callable at any time, including while not paused. Does NOT decrement
    ///      `accountedPrincipal`; the refund obligation continues to exist on book after a
    ///      withdrawal. Use case: draining treasury into the Safe ahead of a PEN→PEN
    ///      migration, or rescuing tokens that were sent here by mistake (airdrops, wrong
    ///      transfers).
    function withdraw(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (address(token) == address(0)) revert InvalidAsset(address(token));
        if (to == address(0)) revert InvalidReceiver(to);
        if (amount == 0) revert InvalidAmount();
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }

    function liquidAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function deployedAssets() public view returns (uint256 assets) {
        IERC4626 currentVault = principalVault;
        if (address(currentVault) != address(0)) {
            uint256 currentShares = currentVault.balanceOf(address(this));
            if (currentShares != 0) {
                assets = currentVault.convertToAssets(currentShares);
            }
        }

        assets += _deployedAssetsFromPreviousVaults(currentVault);
    }

    function totalManagedAssets() public view override returns (uint256) {
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

    function _withdrawFromVault(IERC4626 vault, uint256 assets, address receiver)
        internal
        returns (uint256 shares, address resolvedReceiver)
    {
        if (assets == 0) revert InvalidAmount();
        resolvedReceiver = receiver == address(0) ? address(this) : receiver;
        shares = vault.withdraw(assets, resolvedReceiver, address(this));
    }

    function _depositToPrincipalVault(uint256 assets) internal returns (uint256 shares) {
        IERC4626 currentVault = principalVault;
        if (address(currentVault) == address(0)) revert InvalidPrincipalVault(address(0));

        asset.forceApprove(address(currentVault), assets);
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
        emit PrincipalVaultWithdrawal(address(currentVault), address(this), shortfall, shares);
    }

    function _grantOptionalRole(bytes32 role, address account) internal {
        if (account == address(0)) {
            return;
        }

        _grantRole(role, account);
    }

    function _trackPreviousVault(IERC4626 vault) internal {
        address vaultAddress = address(vault);
        if (_isPreviousPrincipalVault[vaultAddress]) {
            return;
        }

        _isPreviousPrincipalVault[vaultAddress] = true;
        previousPrincipalVaults.push(vault);
    }

    function _deployedAssetsFromPreviousVaults(IERC4626 currentVault) internal view returns (uint256 assets) {
        uint256 length = previousPrincipalVaults.length;

        for (uint256 i; i < length; ++i) {
            IERC4626 vault = previousPrincipalVaults[i];
            if (address(vault) == address(currentVault)) {
                continue; // avoid double-counting when current vault is also historical
            }

            uint256 shares = vault.balanceOf(address(this));
            if (shares == 0) {
                continue;
            }

            assets += vault.convertToAssets(shares);
        }
    }
}
