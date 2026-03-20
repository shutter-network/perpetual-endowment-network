// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {SeatToken} from "../SeatToken.sol";
import {PENRankedChoiceStrategy} from "./PENRankedChoiceStrategy.sol";

contract FundingSlateExecutor is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    error InvalidAdmin(address admin);
    error InvalidConfig();
    error InvalidExecutor(address executor);
    error InvalidSlate(uint16 slateId);
    error InvalidSlateConfig();
    error NotSeatHolder(address account);
    error SlateAlreadyRegistered(uint32 proposalId, uint16 slateId);
    error UnresolvedWinner(uint32 proposalId);

    struct Slate {
        address[] recipients;
        uint256[] amounts;
        uint256 totalAmount;
        bool exists;
    }

    IERC20 public immutable asset;
    IERC4626 public immutable yieldVault;
    PENRankedChoiceStrategy public immutable strategy;
    SeatToken public immutable seatToken;

    mapping(uint32 proposalId => mapping(uint16 slateId => Slate slate)) private _slates;

    event FundingExecuted(
        uint32 indexed proposalId,
        uint16 indexed winningSlate,
        uint256 distributedAmount
    );
    event SlateRegistered(
        uint32 indexed proposalId,
        uint16 indexed slateId,
        address indexed submitter,
        uint256 totalAmount
    );

    constructor(
        IERC20 asset_,
        IERC4626 yieldVault_,
        PENRankedChoiceStrategy strategy_,
        SeatToken seatToken_,
        address admin_,
        address executor_
    ) {
        if (
            address(asset_) == address(0) ||
            address(yieldVault_) == address(0) ||
            address(strategy_) == address(0) ||
            address(seatToken_) == address(0)
        ) {
            revert InvalidConfig();
        }
        if (admin_ == address(0)) revert InvalidAdmin(admin_);
        if (executor_ == address(0)) revert InvalidExecutor(executor_);

        asset = asset_;
        yieldVault = yieldVault_;
        strategy = strategy_;
        seatToken = seatToken_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(EXECUTOR_ROLE, executor_);
    }

    function registerSlate(
        uint32 proposalId_,
        uint16 slateId_,
        address[] calldata recipients_,
        uint256[] calldata amounts_
    ) external {
        if (seatToken.balanceOf(msg.sender) == 0) revert NotSeatHolder(msg.sender);
        if (slateId_ == strategy.DEFAULT_SLATE_ID()) revert InvalidSlate(slateId_);
        if (recipients_.length == 0 || recipients_.length != amounts_.length) {
            revert InvalidSlateConfig();
        }
        if (!_isKnownSlate(proposalId_, slateId_)) revert InvalidSlate(slateId_);

        Slate storage slate = _slates[proposalId_][slateId_];
        if (slate.exists) revert SlateAlreadyRegistered(proposalId_, slateId_);

        slate.exists = true;
        uint256 totalAmount;
        for (uint256 i; i < recipients_.length; ++i) {
            if (recipients_[i] == address(0) || amounts_[i] == 0) {
                revert InvalidSlateConfig();
            }

            slate.recipients.push(recipients_[i]);
            slate.amounts.push(amounts_[i]);
            totalAmount += amounts_[i];
        }
        slate.totalAmount = totalAmount;

        emit SlateRegistered(proposalId_, slateId_, msg.sender, totalAmount);
    }

    function executeFunding(
        uint32 proposalId_
    ) external onlyRole(EXECUTOR_ROLE) returns (uint16 winningSlate, uint256 distributedAmount) {
        bool resolved;
        (winningSlate, resolved) = strategy.getWinningSlate(proposalId_);
        if (!resolved) revert UnresolvedWinner(proposalId_);

        if (winningSlate == strategy.DEFAULT_SLATE_ID()) {
            emit FundingExecuted(proposalId_, winningSlate, 0);
            return (winningSlate, 0);
        }

        Slate storage slate = _slates[proposalId_][winningSlate];
        if (!slate.exists) revert InvalidSlate(winningSlate);

        distributedAmount = slate.totalAmount;
        yieldVault.withdraw(distributedAmount, address(this), address(this));

        for (uint256 i; i < slate.recipients.length; ++i) {
            asset.safeTransfer(slate.recipients[i], slate.amounts[i]);
        }

        emit FundingExecuted(proposalId_, winningSlate, distributedAmount);
    }

    function slateOf(
        uint32 proposalId_,
        uint16 slateId_
    )
        external
        view
        returns (address[] memory recipients, uint256[] memory amounts, uint256 totalAmount, bool exists)
    {
        Slate storage slate = _slates[proposalId_][slateId_];
        recipients = slate.recipients;
        amounts = slate.amounts;
        totalAmount = slate.totalAmount;
        exists = slate.exists;
    }

    function vaultShares() external view returns (uint256) {
        return yieldVault.balanceOf(address(this));
    }

    function _isKnownSlate(uint32 proposalId_, uint16 slateId_) internal view returns (bool) {
        uint16[] memory slateIds = strategy.proposalSlateIds(proposalId_);
        for (uint256 i; i < slateIds.length; ++i) {
            if (slateIds[i] == slateId_) {
                return true;
            }
        }

        return false;
    }
}
