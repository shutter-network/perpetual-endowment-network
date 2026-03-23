// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SeatToken} from "../SeatToken.sol";
import {PENRankedChoiceStrategy} from "./PENRankedChoiceStrategy.sol";

contract FundingSlateExecutor {
    error InvalidConfig();
    error InvalidSlate(uint16 slateId);
    error InvalidSlateConfig();
    error NotSeatHolder(address account);
    error SlateAlreadyRegistered(uint32 proposalId, uint16 slateId);

    struct Slate {
        address[] recipients;
        uint256[] amounts;
        uint256 totalAmount;
        bool exists;
    }

    PENRankedChoiceStrategy public immutable strategy;
    SeatToken public immutable seatToken;

    mapping(uint32 proposalId => mapping(uint16 slateId => Slate slate)) private _slates;

    event SlateRegistered(
        uint32 indexed proposalId,
        uint16 indexed slateId,
        address indexed submitter,
        uint256 totalAmount
    );

    constructor(
        PENRankedChoiceStrategy strategy_,
        SeatToken seatToken_
    ) {
        if (address(strategy_) == address(0) || address(seatToken_) == address(0)) {
            revert InvalidConfig();
        }

        strategy = strategy_;
        seatToken = seatToken_;
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
