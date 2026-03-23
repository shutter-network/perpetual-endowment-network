// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {StrategyV1} from "decent-contracts/contracts/deployables/strategies/StrategyV1.sol";
import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {IVotingWeightV1} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingWeightV1.sol";
import {IVotingWeightERC20V1} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingWeightERC20V1.sol";
import {IVoteTrackerV1} from "decent-contracts/contracts/interfaces/decent/deployables/IVoteTrackerV1.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ISeatActivityToken {
    function recordActivity(address account) external;
}

/// @notice PEN ranked-choice strategy built on top of Decent's Azorius strategy interface.
/// @dev Ballot rankings are encoded in `voteData` as `abi.encode(uint16[])`.
contract PENRankedChoiceStrategy is StrategyV1 {
    bytes32 public constant STRATEGY_KIND = keccak256("PEN_RANKED_CHOICE_V1");
    uint16 public constant DEFAULT_SLATE_ID = 0;

    error DuplicateSlate(uint16 slateId);
    error InconsistentBallotData();
    error InvalidRanking();
    error InvalidRankedChoiceVoteType(uint8 voteType);
    error NotSeatHolder();
    error ProposalAlreadyConfigured(uint32 proposalId);
    error ProposalSlateConfigMissing(uint32 proposalId);
    error RankedBallotAlreadyCast(uint32 proposalId, address voter);

    event ProposalSlatesInitialized(
        uint32 indexed proposalId,
        uint16 indexed defaultSlateId
    );
    event SlateSubmitted(
        uint32 indexed proposalId,
        uint16 indexed slateId,
        address indexed submitter
    );
    event RankedChoiceVoteCast(
        address indexed voter,
        uint32 indexed proposalId,
        uint256 weight,
        uint16[] ranking
    );

    struct RankedChoiceStorage {
        mapping(uint32 proposalId => ProposalSlateConfig config) proposalConfigs;
    }

    struct CastBallot {
        address voter;
        uint256 weight;
        uint16[] ranking;
    }

    struct RoundOutcome {
        uint256 majorityWinnerIndex;
        uint256 eliminationIndex;
        uint256 lastActiveIndex;
        uint256 activeSlateCount;
        bool hasMajorityWinner;
        bool allTied;
    }

    struct ProposalSlateConfig {
        bool configured;
        uint16 defaultSlateId;
        uint16[] slateIds;
        CastBallot[] ballots;
        mapping(uint16 slateId => uint256 indexPlusOne) slateIndexPlusOne;
        mapping(address voter => uint256 ballotIndexPlusOne) ballotIndexPlusOne;
    }

    /**
     * @notice Main storage struct for PENRankedChoiceStrategy following EIP-7201
     * @custom:storage-location erc7201:PEN.RankedChoice.main
     */
    /**
     * @dev Storage slot for RankedChoiceStorage calculated using the EIP-7201 formula:
     * keccak256(abi.encode(uint256(keccak256("PEN.RankedChoice.main")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 internal constant RANKED_CHOICE_STORAGE_LOCATION =
        0xa2f53e5365bf596d914705018ebf313f0316542f781d446f2c920caef2ac2400;

    function _getRankedChoiceStorage()
        internal
        pure
        returns (RankedChoiceStorage storage $)
    {
        assembly {
            $.slot := RANKED_CHOICE_STORAGE_LOCATION
        }
    }

    function initializeProposal(
        uint32 proposalId_
    ) public virtual override onlyStrategyAdmin {
        RankedChoiceStorage storage $ = _getRankedChoiceStorage();
        ProposalSlateConfig storage config = $.proposalConfigs[proposalId_];
        if (config.configured) revert ProposalAlreadyConfigured(proposalId_);

        super.initializeProposal(proposalId_);

        config.configured = true;
        config.defaultSlateId = DEFAULT_SLATE_ID;
        config.slateIds.push(DEFAULT_SLATE_ID);
        config.slateIndexPlusOne[DEFAULT_SLATE_ID] = 1;

        emit ProposalSlatesInitialized(proposalId_, DEFAULT_SLATE_ID);
    }

    function submitSlate(uint32 proposalId_, uint16 slateId_) external {
        ProposalSlateConfig storage config = _requireProposalConfig(proposalId_);
        ProposalVotingDetails memory details = proposalVotingDetails(proposalId_);

        if (block.timestamp > details.votingEndTimestamp) {
            revert ProposalNotActive();
        }

        if (_seatToken().balanceOf(msg.sender) == 0) {
            revert NotSeatHolder();
        }

        if (config.slateIndexPlusOne[slateId_] != 0) {
            revert DuplicateSlate(slateId_);
        }

        config.slateIds.push(slateId_);
        config.slateIndexPlusOne[slateId_] = config.slateIds.length;

        emit SlateSubmitted(proposalId_, slateId_, msg.sender);
    }

    function proposalSlateIds(
        uint32 proposalId_
    ) external view returns (uint16[] memory) {
        ProposalSlateConfig storage config = _requireProposalConfig(proposalId_);
        return config.slateIds;
    }

    function ballotCount(uint32 proposalId_) external view returns (uint256) {
        ProposalSlateConfig storage config = _requireProposalConfig(proposalId_);
        return config.ballots.length;
    }

    function ballotOf(
        uint32 proposalId_,
        address voter_
    ) external view returns (uint16[] memory ranking, uint256 weight) {
        ProposalSlateConfig storage config = _requireProposalConfig(proposalId_);
        uint256 ballotIndexPlusOne = config.ballotIndexPlusOne[voter_];
        if (ballotIndexPlusOne == 0) {
            return (new uint16[](0), 0);
        }

        CastBallot storage ballot = config.ballots[ballotIndexPlusOne - 1];
        return (ballot.ranking, ballot.weight);
    }

    function validStrategyVote(
        address voter_,
        uint32 proposalId_,
        uint8 voteType_,
        IVotingTypes.VotingConfigVoteData[] calldata votingConfigsData_
    ) public view virtual override returns (bool) {
        if (voteType_ != uint8(VoteType.YES)) {
            return false;
        }

        RankedChoiceStorage storage $ = _getRankedChoiceStorage();
        ProposalSlateConfig storage config = $.proposalConfigs[proposalId_];
        if (!config.configured || config.ballotIndexPlusOne[voter_] != 0) {
            return false;
        }

        if (votingConfigsData_.length == 0) {
            return false;
        }

        bytes calldata ballotData = votingConfigsData_[0].voteData;
        for (uint256 i = 1; i < votingConfigsData_.length; ++i) {
            if (keccak256(votingConfigsData_[i].voteData) != keccak256(ballotData)) {
                return false;
            }
        }

        if (!_isBallotEncodingValid(ballotData)) {
            return false;
        }

        uint16[] memory ranking = _decodeBallot(ballotData);
        return _isValidRanking(config, ranking) && super.validStrategyVote(voter_, proposalId_, voteType_, votingConfigsData_);
    }

    function isBasisMet(
        uint32 proposalId_
    ) public view virtual override returns (bool) {
        ProposalVotingDetails memory details = proposalVotingDetails(proposalId_);
        if (details.votingEndTimestamp == 0) revert ProposalNotInitialized();

        (, bool resolved) = getWinningSlate(proposalId_);
        return resolved;
    }

    function isPassed(
        uint32 proposalId_
    ) public view virtual override returns (bool) {
        ProposalVotingDetails memory details = proposalVotingDetails(proposalId_);
        if (details.votingEndTimestamp == 0) revert ProposalNotInitialized();

        if (block.timestamp <= details.votingEndTimestamp) {
            return false;
        }

        (, bool resolved) = getWinningSlate(proposalId_);
        return resolved && isQuorumMet(proposalId_);
    }

    function castVote(
        uint32 proposalId_,
        uint8 voteType_,
        IVotingTypes.VotingConfigVoteData[] calldata votingConfigsData_,
        uint256 lightAccountIndex_
    ) public virtual override {
        if (voteType_ != uint8(VoteType.YES)) {
            revert InvalidRankedChoiceVoteType(voteType_);
        }
        if (votingConfigsData_.length == 0) {
            revert NoVotingConfigs();
        }

        address resolvedVoter = potentialLightAccountResolvedOwner(
            msg.sender,
            lightAccountIndex_
        );

        _castRankedVote(proposalId_, resolvedVoter, votingConfigsData_);
    }

    function getWinningSlate(
        uint32 proposalId_
    ) public view returns (uint16 winner, bool resolved) {
        ProposalSlateConfig storage config = _requireProposalConfig(proposalId_);

        uint256 slateCount = config.slateIds.length;
        bool[] memory eliminated = new bool[](slateCount);
        uint256 remaining = slateCount;

        while (remaining > 0) {
            uint256[] memory tallies = new uint256[](slateCount);
            uint256 activeVotes;

            for (uint256 i = 0; i < config.ballots.length; ++i) {
                CastBallot storage ballot = config.ballots[i];
                uint256 preferredIndex = _firstActivePreferenceIndex(
                    config,
                    eliminated,
                    ballot.ranking
                );
                if (preferredIndex == type(uint256).max) {
                    continue;
                }

                tallies[preferredIndex] += ballot.weight;
                activeVotes += ballot.weight;
            }

            if (activeVotes == 0) {
                return (config.defaultSlateId, true);
            }

            RoundOutcome memory round = _analyzeRound(
                config,
                eliminated,
                tallies,
                activeVotes
            );

            if (round.hasMajorityWinner) {
                return (config.slateIds[round.majorityWinnerIndex], true);
            }

            if (round.activeSlateCount == 1) {
                return (config.slateIds[round.lastActiveIndex], true);
            }

            if (round.allTied) {
                return (config.defaultSlateId, true);
            }

            eliminated[round.eliminationIndex] = true;
            unchecked {
                --remaining;
            }
        }

        return (config.defaultSlateId, false);
    }

    function _castRankedVote(
        uint32 proposalId_,
        address resolvedVoter_,
        IVotingTypes.VotingConfigVoteData[] calldata votingConfigsData_
    ) internal {
        StrategyStorage storage strategyStorage = _getStrategyStorage();
        ProposalVotingDetails storage proposal = strategyStorage
            .proposalVotingDetails[proposalId_];
        if (proposal.votingEndTimestamp == 0) {
            revert ProposalNotInitialized();
        }

        if (block.timestamp > proposal.votingEndTimestamp) {
            if (!strategyStorage.voteCastedAfterVotingPeriodEnded[proposalId_]) {
                strategyStorage.voteCastedAfterVotingPeriodEnded[proposalId_] = true;
                emit VotingPeriodEnded(proposalId_);
                return;
            }
            revert ProposalNotActive();
        }

        RankedChoiceStorage storage rankedChoiceStorage = _getRankedChoiceStorage();
        ProposalSlateConfig storage config = rankedChoiceStorage.proposalConfigs[
            proposalId_
        ];
        if (!config.configured) revert ProposalSlateConfigMissing(proposalId_);
        if (config.ballotIndexPlusOne[resolvedVoter_] != 0) {
            revert RankedBallotAlreadyCast(proposalId_, resolvedVoter_);
        }

        bytes calldata ballotData = votingConfigsData_[0].voteData;
        for (uint256 i = 1; i < votingConfigsData_.length; ++i) {
            if (keccak256(votingConfigsData_[i].voteData) != keccak256(ballotData)) {
                revert InconsistentBallotData();
            }
        }

        uint16[] memory ranking = _decodeBallot(ballotData);
        _validateRankingOrRevert(config, ranking);

        uint256 totalWeightForThisVoteTransaction = _calculateVotingWeightAndRecordVotes(
            strategyStorage,
            proposal,
            proposalId_,
            resolvedVoter_,
            votingConfigsData_
        );

        config.ballotIndexPlusOne[resolvedVoter_] = config.ballots.length + 1;
        CastBallot storage ballot = config.ballots.push();
        ballot.voter = resolvedVoter_;
        ballot.weight = totalWeightForThisVoteTransaction;
        for (uint256 i = 0; i < ranking.length; ++i) {
            ballot.ranking.push(ranking[i]);
        }
        proposal.yesVotes += totalWeightForThisVoteTransaction;
        _recordSeatActivity(resolvedVoter_);

        emit RankedChoiceVoteCast(
            resolvedVoter_,
            proposalId_,
            totalWeightForThisVoteTransaction,
            ranking
        );
        emit Voted(
            resolvedVoter_,
            proposalId_,
            VoteType.YES,
            totalWeightForThisVoteTransaction
        );
    }

    function _decodeBallot(
        bytes calldata encodedBallot_
    ) internal pure returns (uint16[] memory) {
        return abi.decode(encodedBallot_, (uint16[]));
    }

    function _isBallotEncodingValid(
        bytes calldata encodedBallot_
    ) internal pure returns (bool) {
        if (encodedBallot_.length < 64 || encodedBallot_.length % 32 != 0) {
            return false;
        }

        uint256 offset;
        uint256 rankingLength;
        assembly {
            offset := calldataload(encodedBallot_.offset)
            rankingLength := calldataload(add(encodedBallot_.offset, 0x20))
        }

        if (offset != 32) {
            return false;
        }

        return encodedBallot_.length == 64 + (rankingLength * 32);
    }

    function _calculateVotingWeightAndRecordVotes(
        StrategyStorage storage strategyStorage_,
        ProposalVotingDetails storage proposal_,
        uint32 proposalId_,
        address voter_,
        IVotingTypes.VotingConfigVoteData[] calldata votingConfigsData_
    ) internal returns (uint256 totalWeight) {
        for (uint256 i = 0; i < votingConfigsData_.length; ++i) {
            IVotingTypes.VotingConfigVoteData memory configData = votingConfigsData_[i];

            if (configData.configIndex >= strategyStorage_.votingConfigs.length) {
                revert InvalidVotingConfig(configData.configIndex);
            }

            IVotingTypes.VotingConfig memory votingConfig = strategyStorage_
                .votingConfigs[configData.configIndex];

            (uint256 votingWeight, bytes memory processedData) = IVotingWeightV1(
                votingConfig.votingWeight
            ).calculateWeight(voter_, proposal_.votingStartTimestamp, configData.voteData);

            if (votingWeight == 0) {
                revert NoVotingWeight(configData.configIndex);
            }

            IVoteTrackerV1(votingConfig.voteTracker).recordVote(
                proposalId_,
                voter_,
                processedData
            );

            totalWeight += votingWeight;
        }
    }

    function _requireProposalConfig(
        uint32 proposalId_
    ) internal view returns (ProposalSlateConfig storage config) {
        ProposalVotingDetails memory details = proposalVotingDetails(proposalId_);
        if (details.votingEndTimestamp == 0) revert ProposalNotInitialized();

        RankedChoiceStorage storage $ = _getRankedChoiceStorage();
        config = $.proposalConfigs[proposalId_];
        if (!config.configured) revert ProposalSlateConfigMissing(proposalId_);
    }

    function _seatToken() internal view returns (IERC20) {
        StrategyStorage storage $ = _getStrategyStorage();
        return IERC20(
            IVotingWeightERC20V1($.votingConfigs[0].votingWeight).token()
        );
    }

    function _recordSeatActivity(address voter_) internal {
        ISeatActivityToken(address(_seatToken())).recordActivity(voter_);
    }

    function _validateRankingOrRevert(
        ProposalSlateConfig storage config,
        uint16[] memory ranking
    ) internal view {
        if (!_isValidRanking(config, ranking)) revert InvalidRanking();
    }

    function _isValidRanking(
        ProposalSlateConfig storage config,
        uint16[] memory ranking
    ) internal view returns (bool) {
        if (ranking.length == 0) {
            return false;
        }

        bool[] memory seen = new bool[](config.slateIds.length);
        for (uint256 i = 0; i < ranking.length; ++i) {
            uint16 slateId = ranking[i];
            uint256 indexPlusOne = config.slateIndexPlusOne[slateId];
            if (indexPlusOne == 0) {
                return false;
            }

            uint256 index = indexPlusOne - 1;
            if (seen[index]) {
                return false;
            }

            seen[index] = true;
        }

        return true;
    }

    function _firstActivePreferenceIndex(
        ProposalSlateConfig storage config,
        bool[] memory eliminated,
        uint16[] storage ranking_
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < ranking_.length; ++i) {
            uint256 index = config.slateIndexPlusOne[ranking_[i]];
            if (index == 0) {
                continue;
            }

            unchecked {
                --index;
            }

            if (!eliminated[index]) {
                return index;
            }
        }

        return type(uint256).max;
    }

    function _analyzeRound(
        ProposalSlateConfig storage config,
        bool[] memory eliminated,
        uint256[] memory tallies,
        uint256 activeVotes
    ) internal view returns (RoundOutcome memory outcome) {
        uint256 minVotes = type(uint256).max;
        uint16 highestSlateIdAtMin;
        uint256 firstActiveTally;
        bool defaultSlateAtMin;
        bool firstActiveSeen;

        for (uint256 i = 0; i < config.slateIds.length; ++i) {
            if (eliminated[i]) {
                continue;
            }

            uint16 slateId = config.slateIds[i];
            outcome.lastActiveIndex = i;
            ++outcome.activeSlateCount;

            if (tallies[i] * 2 > activeVotes) {
                outcome.majorityWinnerIndex = i;
                outcome.hasMajorityWinner = true;
            }

            if (!firstActiveSeen) {
                firstActiveTally = tallies[i];
                outcome.allTied = true;
                firstActiveSeen = true;
            } else if (tallies[i] != firstActiveTally) {
                outcome.allTied = false;
            }

            if (tallies[i] < minVotes) {
                minVotes = tallies[i];
                outcome.eliminationIndex = i;
                highestSlateIdAtMin = slateId;
                defaultSlateAtMin = slateId == config.defaultSlateId;
            } else if (tallies[i] == minVotes) {
                bool isDefaultSlate = slateId == config.defaultSlateId;
                if (isDefaultSlate && !defaultSlateAtMin) {
                    outcome.eliminationIndex = i;
                    highestSlateIdAtMin = slateId;
                    defaultSlateAtMin = true;
                } else if (
                    !defaultSlateAtMin &&
                    !isDefaultSlate &&
                    slateId > highestSlateIdAtMin
                ) {
                    outcome.eliminationIndex = i;
                    highestSlateIdAtMin = slateId;
                }
            }
        }
    }
}
