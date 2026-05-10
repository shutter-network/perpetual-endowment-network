// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StrategyV1} from "decent-contracts/contracts/deployables/strategies/StrategyV1.sol";
import {ISeatToken} from "../interfaces/ISeatToken.sol";
import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {IVotingWeightERC20V1} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingWeightERC20V1.sol";

/// @notice PEN-owned wrapper around Decent `StrategyV1` that refreshes SeatToken activity on successful vote casts.
contract PENStrategyV1 is StrategyV1 {
    function _seatToken() internal view returns (ISeatToken) {
        IVotingTypes.VotingConfig memory config = votingConfig(0);
        address token = IVotingWeightERC20V1(config.votingWeight).token();
        return ISeatToken(token);
    }

    /// @inheritdoc StrategyV1
    function castVote(
        uint32 proposalId_,
        uint8 voteType_,
        IVotingTypes.VotingConfigVoteData[] calldata votingConfigsData_,
        uint256 lightAccountIndex_
    ) public virtual override {
        super.castVote(proposalId_, voteType_, votingConfigsData_, lightAccountIndex_);

        address resolvedVoter = potentialLightAccountResolvedOwner(msg.sender, lightAccountIndex_);
        ProposalVotingDetails memory details = proposalVotingDetails(proposalId_);

        if (block.timestamp <= details.votingEndTimestamp) {
            _seatToken().recordActivity(resolvedVoter);
        }
    }
}
