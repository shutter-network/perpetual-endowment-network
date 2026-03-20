// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {PrincipalManager} from "./PrincipalManager.sol";
import {SeatToken} from "./SeatToken.sol";

contract BondingTranche is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant RECLAIMER_ROLE = keccak256("RECLAIMER_ROLE");

    error HolderStillActive(address holder);
    error InvalidAdmin(address admin);
    error InvalidAmount();
    error InvalidPrice(uint256 price);
    error InvalidRecipient(address recipient);
    error InvalidRefundReceiver(address receiver);
    error InvalidTrancheConfiguration();
    error PurchaseCostExceedsLimit(uint256 cost, uint256 maxCost);
    error SoldOut();

    SeatToken public immutable seatToken;
    PrincipalManager public immutable principalManager;
    IERC20 public immutable asset;
    uint256 public immutable refundPrice;

    uint256[] private _trancheUpperBounds;
    uint256[] private _tranchePrices;

    event SeatsPurchased(
        address indexed payer, address indexed recipient, uint256 seats, uint256 totalCost, uint256 newTotalSupply
    );
    event SeatsRefunded(
        address indexed holder, address indexed receiver, uint256 seats, uint256 refundAmount, uint256 newTotalSupply
    );
    event SeatsReclaimed(address indexed holder, uint256 seats, uint256 newTotalSupply);

    constructor(
        SeatToken seatToken_,
        PrincipalManager principalManager_,
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

        uint256 previousUpperBound;
        uint256 length = trancheUpperBounds_.length;
        for (uint256 i; i < length; ++i) {
            uint256 upperBound = trancheUpperBounds_[i];
            uint256 price = tranchePrices_[i];

            if (upperBound <= previousUpperBound || price == 0) revert InvalidTrancheConfiguration();
            previousUpperBound = upperBound;
        }

        if (trancheUpperBounds_[length - 1] != seatToken_.supplyCap()) {
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

    function quotePurchase(uint256 amount) public view returns (uint256 totalCost) {
        if (amount == 0) revert InvalidAmount();

        uint256 remaining = amount;
        uint256 currentSupply = seatToken.totalSupply();
        uint256 length = _trancheUpperBounds.length;

        for (uint256 i; i < length; ++i) {
            uint256 upperBound = _trancheUpperBounds[i];
            if (currentSupply >= upperBound) {
                continue;
            }

            uint256 availableInTranche = upperBound - currentSupply;
            uint256 seatsAtThisPrice = remaining < availableInTranche ? remaining : availableInTranche;

            totalCost += seatsAtThisPrice * _tranchePrices[i];
            currentSupply += seatsAtThisPrice;
            remaining -= seatsAtThisPrice;

            if (remaining == 0) {
                return totalCost;
            }
        }

        revert SoldOut();
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
        if (recipient == address(0)) revert InvalidRecipient(recipient);

        totalCost = quotePurchase(amount);
        if (totalCost > maxCost) revert PurchaseCostExceedsLimit(totalCost, maxCost);

        asset.safeTransferFrom(msg.sender, address(principalManager), totalCost);
        principalManager.recordPurchase(totalCost);
        seatToken.mint(recipient, amount);

        emit SeatsPurchased(msg.sender, recipient, amount, totalCost, seatToken.totalSupply());
    }

    function refund(uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 refundAmount)
    {
        address refundReceiver = receiver == address(0) ? msg.sender : receiver;
        if (refundReceiver == address(0)) revert InvalidRefundReceiver(refundReceiver);

        refundAmount = quoteRefund(amount);
        seatToken.burn(msg.sender, amount);
        principalManager.payRefund(refundReceiver, refundAmount);

        emit SeatsRefunded(msg.sender, refundReceiver, amount, refundAmount, seatToken.totalSupply());
    }

    function reclaim(address holder) external onlyRole(RECLAIMER_ROLE) nonReentrant returns (uint256 reclaimedSeats) {
        if (!seatToken.isInactive(holder)) revert HolderStillActive(holder);

        reclaimedSeats = seatToken.balanceOf(holder);
        if (reclaimedSeats == 0) revert InvalidAmount();

        seatToken.burn(holder, reclaimedSeats);
        emit SeatsReclaimed(holder, reclaimedSeats, seatToken.totalSupply());
    }

    function _grantOptionalRole(bytes32 role, address account) internal {
        if (account == address(0)) {
            return;
        }

        _grantRole(role, account);
    }
}
