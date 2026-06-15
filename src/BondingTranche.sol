// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IPrincipalManager} from "./interfaces/IPrincipalManager.sol";
import {ISeatToken} from "./interfaces/ISeatToken.sol";

contract BondingTranche is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant RECLAIMER_ROLE = keccak256("RECLAIMER_ROLE");

    error HolderStillActive(address holder);
    error InvalidAdmin(address admin);
    error InvalidAmount();
    error InvalidRecipient(address recipient);
    error InvalidRefundReceiver(address receiver);
    error InvalidTrancheConfiguration();
    error PrincipalManagerPaused();
    error PurchaseCostExceedsLimit(uint256 cost, uint256 maxCost);
    error InsufficientSeatsAvailable(uint256 requested, uint256 available);
    error RefundObligationExceedsManagedAssets(uint256 obligation, uint256 managedAssets);

    ISeatToken public immutable seatToken;
    IPrincipalManager public immutable principalManager;
    IERC20 public immutable asset;
    uint256 public immutable refundPrice;

    uint256[] private _trancheUpperBounds;
    uint256[] private _tranchePrices;

    event TrancheExtended(uint256 previousUpperBound, uint256 newUpperBound, uint256 pricePerSeat);

    event SeatsPurchased(
        address indexed payer, address indexed recipient, uint256 seats, uint256 totalCost, uint256 newTotalSupply
    );
    event SeatsRefunded(
        address indexed holder, address indexed receiver, uint256 seats, uint256 refundAmount, uint256 newTotalSupply
    );
    event SeatsReclaimed(address indexed holder, uint256 seats, uint256 newTotalSupply);

    constructor(
        ISeatToken seatToken_,
        IPrincipalManager principalManager_,
        uint256 refundPrice_,
        address admin_,
        address reclaimer_,
        uint256[] memory trancheUpperBounds_,
        uint256[] memory tranchePrices_
    ) {
        if (address(seatToken_) == address(0) || address(principalManager_) == address(0)) {
            revert InvalidTrancheConfiguration();
        }
        if (admin_ == address(0)) revert InvalidAdmin(admin_);
        if (trancheUpperBounds_.length == 0 || trancheUpperBounds_.length != tranchePrices_.length) {
            revert InvalidTrancheConfiguration();
        }

        // Both `upperBound` and `price` must be strictly increasing across tranches:
        // - first values must be > 0 (initial `previousUpperBound` and `previousPrice` are 0),
        // - each subsequent value must exceed the previous.
        // A tranche that repeats the previous price is redundant (just widen the previous tranche).
        uint256 previousUpperBound;
        uint256 previousPrice;
        uint256 length = trancheUpperBounds_.length;
        for (uint256 i; i < length; ++i) {
            uint256 upperBound = trancheUpperBounds_[i];
            uint256 price = tranchePrices_[i];

            if (upperBound <= previousUpperBound || price <= previousPrice) revert InvalidTrancheConfiguration();

            previousUpperBound = upperBound;
            previousPrice = price;
        }

        // The bonding tranche sale cap is determined by the final tranche upper bound.
        if (trancheUpperBounds_[length - 1] > seatToken_.supplyCap()) {
            revert InvalidTrancheConfiguration();
        }

        seatToken = seatToken_;
        principalManager = principalManager_;
        asset = principalManager_.asset();
        refundPrice = refundPrice_;
        _trancheUpperBounds = trancheUpperBounds_;
        _tranchePrices = tranchePrices_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantOptionalRole(RECLAIMER_ROLE, reclaimer_);
    }

    function trancheCount() external view returns (uint256) {
        return _trancheUpperBounds.length;
    }

    function tranche(uint256 index) external view returns (uint256 upperBound, uint256 pricePerSeat) {
        upperBound = _trancheUpperBounds[index];
        pricePerSeat = _tranchePrices[index];
    }

    /// @notice Append new tranche(s) to extend the sale cap (governance-controlled).
    /// @dev Both `newUpperBounds` and `newPrices` must be strictly greater than the previous
    ///      tranche's values (and strictly increasing across the appended tranches).
    ///      Each `upperBound` must also exceed the current `SeatToken.totalSupply()` and stay
    ///      within `SeatToken.supplyCap()`.
    function extendTranches(uint256[] calldata newUpperBounds, uint256[] calldata newPrices)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        uint256 length = newUpperBounds.length;
        if (length == 0 || length != newPrices.length) revert InvalidTrancheConfiguration();

        uint256 previousUpperBound = _trancheUpperBounds[_trancheUpperBounds.length - 1];
        uint256 previousPrice = _tranchePrices[_tranchePrices.length - 1];
        for (uint256 i; i < length; ++i) {
            uint256 upperBound = newUpperBounds[i];
            uint256 price = newPrices[i];

            if (upperBound <= previousUpperBound || price <= previousPrice) revert InvalidTrancheConfiguration();
            if (upperBound > seatToken.supplyCap()) revert InvalidTrancheConfiguration();

            _trancheUpperBounds.push(upperBound);
            _tranchePrices.push(price);
            emit TrancheExtended(previousUpperBound, upperBound, price);

            previousUpperBound = upperBound;
            previousPrice = price;
        }
    }

    function quotePurchase(uint256 amount) public view returns (uint256 totalCost) {
        if (amount == 0) revert InvalidAmount();

        uint256 currentSupply = IERC20(address(seatToken)).totalSupply();
        uint256 length = _trancheUpperBounds.length;

        // Locate the active tranche: the first one whose upper bound has not yet been reached.
        uint256 start;
        while (start < length && currentSupply >= _trancheUpperBounds[start]) {
            ++start;
        }
        if (start == length) revert InsufficientSeatsAvailable(amount, 0);

        // Fill from the active tranche onward. The active tranche fills from `currentSupply`;
        // every subsequent tranche fills from the previous tranche's upper bound.
        uint256 remaining = amount;
        uint256 trancheFloor = currentSupply;
        for (uint256 i = start; i < length; ++i) {
            uint256 upperBound = _trancheUpperBounds[i];
            uint256 availableInTranche = upperBound - trancheFloor;
            uint256 seatsAtThisPrice = remaining < availableInTranche ? remaining : availableInTranche;

            totalCost += seatsAtThisPrice * _tranchePrices[i];
            remaining -= seatsAtThisPrice;

            if (remaining == 0) return totalCost;

            trancheFloor = upperBound;
        }

        revert InsufficientSeatsAvailable(amount, amount - remaining);
    }

    function quoteRefund(uint256 amount) public view returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        return amount * refundPrice;
    }

    function currentSeatPrice() external view returns (uint256) {
        return quotePurchase(1);
    }

    function purchase(address recipient, uint256 amount, uint256 maxCost)
        external
        nonReentrant
        returns (uint256 totalCost)
    {
        if (principalManager.paused()) revert PrincipalManagerPaused();
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        totalCost = quotePurchase(amount);
        if (totalCost > maxCost) revert PurchaseCostExceedsLimit(totalCost, maxCost);

        asset.safeTransferFrom(msg.sender, address(principalManager), totalCost);
        principalManager.recordPurchase(totalCost);
        seatToken.mint(recipient, amount);

        emit SeatsPurchased(msg.sender, recipient, amount, totalCost, IERC20(address(seatToken)).totalSupply());
    }

    function refund(uint256 amount, address receiver) external nonReentrant returns (uint256 refundAmount) {
        if (principalManager.paused()) revert PrincipalManagerPaused();
        address refundReceiver = receiver == address(0) ? msg.sender : receiver;
        if (refundReceiver == address(0)) revert InvalidRefundReceiver(refundReceiver);

        refundAmount = quoteRefund(amount);

        // Block refunds when managed assets can't cover the refund obligation across all outstanding seats.
        // Pre-burn check: totalManagedAssets() must cover totalSupply * refundPrice.
        uint256 obligation = IERC20(address(seatToken)).totalSupply() * refundPrice;
        uint256 managedAssets = principalManager.totalManagedAssets();
        if (managedAssets < obligation) revert RefundObligationExceedsManagedAssets(obligation, managedAssets);

        seatToken.burn(msg.sender, amount);
        principalManager.payRefund(refundReceiver, refundAmount);

        emit SeatsRefunded(msg.sender, refundReceiver, amount, refundAmount, IERC20(address(seatToken)).totalSupply());
    }

    function reclaim(address holder) external onlyRole(RECLAIMER_ROLE) nonReentrant returns (uint256 reclaimedSeats) {
        if (principalManager.paused()) revert PrincipalManagerPaused();
        if (!seatToken.isInactive(holder)) revert HolderStillActive(holder);

        reclaimedSeats = IERC20(address(seatToken)).balanceOf(holder);
        if (reclaimedSeats == 0) revert InvalidAmount();

        seatToken.burn(holder, reclaimedSeats);
        emit SeatsReclaimed(holder, reclaimedSeats, IERC20(address(seatToken)).totalSupply());
    }

    function _grantOptionalRole(bytes32 role, address account) internal {
        if (account == address(0)) {
            return;
        }

        _grantRole(role, account);
    }
}
