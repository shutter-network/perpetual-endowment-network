// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {PENRankedChoiceStrategy} from "../src/governance/PENRankedChoiceStrategy.sol";

import {IStrategyV1} from "decent-contracts/contracts/interfaces/decent/deployables/IStrategyV1.sol";
import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {VotingWeightERC20V1} from "decent-contracts/contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import {VoteTrackerERC20V1} from "decent-contracts/contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";

contract WinningSlateGasProbe {
    function measure(
        PENRankedChoiceStrategy strategy_,
        uint32 proposalId_
    ) external view returns (uint256 gasUsed, uint16 winner, bool resolved) {
        uint256 gasBefore = gasleft();
        (winner, resolved) = strategy_.getWinningSlate(proposalId_);
        gasUsed = gasBefore - gasleft();
    }
}

contract PENRankedChoiceStrategyTest is Test {
    uint32 internal constant VOTING_PERIOD = 3 days;
    uint32 internal constant PROPOSAL_ID = 1;
    address internal constant PROPOSER_ADAPTER = address(0xBEEF);
    uint256 internal constant REPRESENTATIVE_BLOCK_GAS_LIMIT = 30_000_000;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    address internal dave = address(0xDAA1E);
    address internal eve = makeAddr("eve");

    SeatToken internal seatToken;
    PENRankedChoiceStrategy internal strategy;
    VotingWeightERC20V1 internal votingWeight;
    VoteTrackerERC20V1 internal voteTracker;
    WinningSlateGasProbe internal gasProbe;
    uint32 internal nextStressProposalId = 10_000;

    function setUp() public {
        seatToken = new SeatToken(
            "PEN Seat",
            "SEAT",
            10_000_000,
            365 days,
            address(this),
            address(this),
            address(this),
            address(0)
        );

        _mintSeats(alice, 4);
        _mintSeats(bob, 3);
        _mintSeats(carol, 2);
        _mintSeats(dave, 1);

        vm.warp(block.timestamp + 1);

        strategy = _deployStrategy();
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), address(strategy));
        votingWeight = _deployVotingWeight();
        voteTracker = _deployVoteTracker(address(strategy));

        strategy.initialize(VOTING_PERIOD, 6, 500_001, _singleAdapter(PROPOSER_ADAPTER), address(0));
        strategy.initialize2(
            address(this),
            _singleVotingConfig(address(votingWeight), address(voteTracker))
        );
        gasProbe = new WinningSlateGasProbe();
    }

    function test_InitializeStoresVotingSetup() public view {
        assertEq(strategy.strategyAdmin(), address(this));
        assertEq(strategy.votingPeriod(), VOTING_PERIOD);
        assertEq(strategy.quorumThreshold(), 6);
        assertEq(strategy.basisNumerator(), 500_001);
        assertTrue(strategy.isProposerAdapter(PROPOSER_ADAPTER));

        address[] memory proposerAdapters = strategy.proposerAdapters();
        assertEq(proposerAdapters.length, 1);
        assertEq(proposerAdapters[0], PROPOSER_ADAPTER);

        IVotingTypes.VotingConfig[] memory votingConfigs = strategy.votingConfigs();
        assertEq(votingConfigs.length, 1);
        assertEq(votingConfigs[0].votingWeight, address(votingWeight));
        assertEq(votingConfigs[0].voteTracker, address(voteTracker));
    }

    function test_RevertWhenInitializeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        strategy.initialize(VOTING_PERIOD, 6, 500_001, _singleAdapter(PROPOSER_ADAPTER), address(0));
    }

    function test_RevertWhenInitialize2CalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        strategy.initialize2(address(this), _singleVotingConfig(address(votingWeight), address(voteTracker)));
    }

    function test_InitializeProposalCreatesDefaultSlate() public {
        strategy.initializeProposal(PROPOSAL_ID);

        IStrategyV1.ProposalVotingDetails memory details = strategy.proposalVotingDetails(PROPOSAL_ID);
        assertEq(details.yesVotes, 0);
        assertEq(details.noVotes, 0);
        assertEq(details.abstainVotes, 0);
        assertEq(details.votingStartTimestamp, block.timestamp);
        assertEq(details.votingEndTimestamp, block.timestamp + VOTING_PERIOD);

        uint16[] memory slateIds = strategy.proposalSlateIds(PROPOSAL_ID);
        assertEq(slateIds.length, 1);
        assertEq(slateIds[0], 0);
        assertEq(strategy.ballotCount(PROPOSAL_ID), 0);
    }

    function test_RevertWhenNonAdminInitializesProposal() public {
        vm.prank(alice);
        vm.expectRevert(IStrategyV1.InvalidStrategyAdmin.selector);
        strategy.initializeProposal(PROPOSAL_ID);
    }

    function test_RevertWhenInitializingProposalTwice() public {
        strategy.initializeProposal(PROPOSAL_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                PENRankedChoiceStrategy.ProposalAlreadyConfigured.selector,
                PROPOSAL_ID
            )
        );
        strategy.initializeProposal(PROPOSAL_ID);
    }

    function test_SubmitSlateAllowsSeatHoldersAndPreservesInsertionOrder() public {
        strategy.initializeProposal(PROPOSAL_ID);

        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);
        vm.prank(bob);
        strategy.submitSlate(PROPOSAL_ID, 2);
        vm.prank(carol);
        strategy.submitSlate(PROPOSAL_ID, 5);

        uint16[] memory slateIds = strategy.proposalSlateIds(PROPOSAL_ID);
        assertEq(slateIds.length, 4);
        assertEq(slateIds[0], 0);
        assertEq(slateIds[1], 1);
        assertEq(slateIds[2], 2);
        assertEq(slateIds[3], 5);
    }

    function test_SubmitSlateAtVotingEndTimestampStillAllowed() public {
        strategy.initializeProposal(PROPOSAL_ID);
        uint48 votingEndTimestamp = strategy.proposalVotingDetails(PROPOSAL_ID).votingEndTimestamp;

        vm.warp(votingEndTimestamp);
        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);

        uint16[] memory slateIds = strategy.proposalSlateIds(PROPOSAL_ID);
        assertEq(slateIds.length, 2);
        assertEq(slateIds[1], 1);
    }

    function test_RevertWhenNonHolderSubmitsSlate() public {
        strategy.initializeProposal(PROPOSAL_ID);

        vm.prank(eve);
        vm.expectRevert(
            abi.encodeWithSelector(PENRankedChoiceStrategy.NotSeatHolder.selector, eve)
        );
        strategy.submitSlate(PROPOSAL_ID, 1);
    }

    function test_RevertWhenSubmittingDefaultSlate() public {
        strategy.initializeProposal(PROPOSAL_ID);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PENRankedChoiceStrategy.DuplicateSlate.selector,
                uint16(0)
            )
        );
        strategy.submitSlate(PROPOSAL_ID, 0);
    }

    function test_RevertWhenSubmittingDuplicateSlate() public {
        strategy.initializeProposal(PROPOSAL_ID);

        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(PENRankedChoiceStrategy.DuplicateSlate.selector, uint16(1))
        );
        strategy.submitSlate(PROPOSAL_ID, 1);
    }

    function test_RevertWhenSubmittingSlateAfterVotingEnds() public {
        strategy.initializeProposal(PROPOSAL_ID);
        vm.warp(strategy.proposalVotingDetails(PROPOSAL_ID).votingEndTimestamp + 1);

        vm.prank(alice);
        vm.expectRevert(IStrategyV1.ProposalNotActive.selector);
        strategy.submitSlate(PROPOSAL_ID, 1);
    }

    function test_BallotHelpersReflectVotingState() public {
        _initializeProposalWithTwoSlates();

        (uint16[] memory rankingBefore, uint256 weightBefore) = strategy.ballotOf(PROPOSAL_ID, alice);
        assertEq(rankingBefore.length, 0);
        assertEq(weightBefore, 0);
        assertEq(strategy.ballotCount(PROPOSAL_ID), 0);

        _castVote(alice, _ranking(1, 2, 0));

        (uint16[] memory rankingAfter, uint256 weightAfter) = strategy.ballotOf(PROPOSAL_ID, alice);
        assertEq(rankingAfter.length, 3);
        assertEq(rankingAfter[0], 1);
        assertEq(rankingAfter[1], 2);
        assertEq(rankingAfter[2], 0);
        assertEq(weightAfter, 4);
        assertEq(strategy.ballotCount(PROPOSAL_ID), 1);
    }

    function test_ValidStrategyVoteReturnsTrueForValidBallotAndFalseAfterVote() public {
        _initializeProposalWithTwoSlates();

        IVotingTypes.VotingConfigVoteData[] memory validVote = _voteData(_ranking(1, 2, 0));
        assertTrue(strategy.validStrategyVote(alice, PROPOSAL_ID, 1, validVote));

        _castVote(alice, _ranking(1, 2, 0));

        assertFalse(strategy.validStrategyVote(alice, PROPOSAL_ID, 1, validVote));
    }

    function test_ValidStrategyVoteReturnsFalseForInvalidInputs() public {
        _initializeProposalWithTwoSlates();

        IVotingTypes.VotingConfigVoteData[] memory validVote = _voteData(_ranking(1, 2, 0));
        assertFalse(strategy.validStrategyVote(alice, PROPOSAL_ID, 0, validVote));
        assertFalse(strategy.validStrategyVote(eve, PROPOSAL_ID, 1, validVote));

        IVotingTypes.VotingConfigVoteData[] memory noConfigs = new IVotingTypes.VotingConfigVoteData[](0);
        assertFalse(strategy.validStrategyVote(alice, PROPOSAL_ID, 1, noConfigs));

        IVotingTypes.VotingConfigVoteData[] memory invalidConfigVote = new IVotingTypes.VotingConfigVoteData[](1);
        invalidConfigVote[0] = IVotingTypes.VotingConfigVoteData({
            configIndex: 1,
            voteData: abi.encode(_ranking(1, 2, 0))
        });
        assertFalse(strategy.validStrategyVote(alice, PROPOSAL_ID, 1, invalidConfigVote));

        IVotingTypes.VotingConfigVoteData[] memory malformedVote = new IVotingTypes.VotingConfigVoteData[](1);
        malformedVote[0] = IVotingTypes.VotingConfigVoteData({
            configIndex: 0,
            voteData: abi.encode(uint16(1))
        });
        assertFalse(strategy.validStrategyVote(alice, PROPOSAL_ID, 1, malformedVote));

        IVotingTypes.VotingConfigVoteData[] memory unknownSlateVote = _voteData(_ranking(1, 77));
        assertFalse(strategy.validStrategyVote(alice, PROPOSAL_ID, 1, unknownSlateVote));

        IVotingTypes.VotingConfigVoteData[] memory duplicateSlateVote = _voteData(_ranking(1, 2, 1));
        assertFalse(strategy.validStrategyVote(alice, PROPOSAL_ID, 1, duplicateSlateVote));
    }

    function test_CastVoteStoresWeightAndUpdatesActivity() public {
        vm.warp(block.timestamp + 366 days);
        assertTrue(seatToken.isInactive(alice));

        _initializeProposalWithTwoSlates();
        uint48 previousActivity = seatToken.lastActivityAt(alice);

        _castVote(alice, _ranking(1, 2, 0));

        IStrategyV1.ProposalVotingDetails memory details = strategy.proposalVotingDetails(PROPOSAL_ID);
        assertEq(details.yesVotes, 4);
        assertEq(strategy.ballotCount(PROPOSAL_ID), 1);
        assertFalse(seatToken.isInactive(alice));
        assertGt(seatToken.lastActivityAt(alice), previousActivity);
    }

    function test_RevertWhenVoteTypeIsNotYes() public {
        _initializeProposalWithTwoSlates();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PENRankedChoiceStrategy.InvalidRankedChoiceVoteType.selector,
                uint8(0)
            )
        );
        strategy.castVote(PROPOSAL_ID, 0, _voteData(_ranking(1, 2, 0)), 0);
    }

    function test_RevertWhenCastVoteHasNoVotingConfigs() public {
        _initializeProposalWithTwoSlates();

        IVotingTypes.VotingConfigVoteData[] memory noConfigs = new IVotingTypes.VotingConfigVoteData[](0);

        vm.prank(alice);
        vm.expectRevert(IStrategyV1.NoVotingConfigs.selector);
        strategy.castVote(PROPOSAL_ID, 1, noConfigs, 0);
    }

    function test_RevertWhenVotingConfigIndexIsInvalid() public {
        _initializeProposalWithTwoSlates();

        IVotingTypes.VotingConfigVoteData[] memory invalidConfigVote = new IVotingTypes.VotingConfigVoteData[](1);
        invalidConfigVote[0] = IVotingTypes.VotingConfigVoteData({
            configIndex: 1,
            voteData: abi.encode(_ranking(1, 2, 0))
        });

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyV1.InvalidVotingConfig.selector, uint256(1))
        );
        strategy.castVote(PROPOSAL_ID, 1, invalidConfigVote, 0);
    }

    function test_RevertWhenVoterCastsSecondBallot() public {
        _initializeProposalWithTwoSlates();

        _castVote(alice, _ranking(1, 2, 0));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PENRankedChoiceStrategy.RankedBallotAlreadyCast.selector,
                PROPOSAL_ID,
                alice
            )
        );
        strategy.castVote(PROPOSAL_ID, 1, _voteData(_ranking(2, 1, 0)), 0);
    }

    function test_RevertWhenVoteDataIsInconsistentAcrossConfigs() public {
        PENRankedChoiceStrategy dualConfigStrategy = _deployStrategyWithTwoVotingConfigs();
        _initializeProposalWithTwoSlates(dualConfigStrategy, PROPOSAL_ID);

        IVotingTypes.VotingConfigVoteData[] memory inconsistentVote = new IVotingTypes.VotingConfigVoteData[](2);
        inconsistentVote[0] = IVotingTypes.VotingConfigVoteData({
            configIndex: 0,
            voteData: abi.encode(_ranking(1, 2, 0))
        });
        inconsistentVote[1] = IVotingTypes.VotingConfigVoteData({
            configIndex: 1,
            voteData: abi.encode(_ranking(2, 1, 0))
        });

        assertFalse(dualConfigStrategy.validStrategyVote(alice, PROPOSAL_ID, 1, inconsistentVote));

        vm.prank(alice);
        vm.expectRevert(PENRankedChoiceStrategy.InconsistentBallotData.selector);
        dualConfigStrategy.castVote(PROPOSAL_ID, 1, inconsistentVote, 0);
    }

    function test_RevertWhenBallotEncodingIsMalformed() public {
        _initializeProposalWithTwoSlates();

        IVotingTypes.VotingConfigVoteData[] memory malformedVote = new IVotingTypes.VotingConfigVoteData[](1);
        malformedVote[0] = IVotingTypes.VotingConfigVoteData({
            configIndex: 0,
            voteData: abi.encode(uint16(1))
        });

        vm.prank(alice);
        vm.expectRevert();
        strategy.castVote(PROPOSAL_ID, 1, malformedVote, 0);
    }

    function test_RevertWhenRankingContainsNoSlates() public {
        _initializeProposalWithTwoSlates();

        IVotingTypes.VotingConfigVoteData[] memory emptyRankingVote = _voteData(new uint16[](0));
        assertFalse(strategy.validStrategyVote(alice, PROPOSAL_ID, 1, emptyRankingVote));

        vm.prank(alice);
        vm.expectRevert(PENRankedChoiceStrategy.InvalidRanking.selector);
        strategy.castVote(PROPOSAL_ID, 1, emptyRankingVote, 0);
    }

    function test_RevertWhenRankingContainsUnknownSlate() public {
        _initializeProposalWithTwoSlates();

        IVotingTypes.VotingConfigVoteData[] memory voteData = _voteData(_ranking(1, 77));

        vm.prank(alice);
        vm.expectRevert(PENRankedChoiceStrategy.InvalidRanking.selector);
        strategy.castVote(PROPOSAL_ID, 1, voteData, 0);
    }

    function test_RevertWhenRankingContainsDuplicateSlate() public {
        _initializeProposalWithTwoSlates();

        IVotingTypes.VotingConfigVoteData[] memory voteData = _voteData(_ranking(1, 2, 1));

        vm.prank(alice);
        vm.expectRevert(PENRankedChoiceStrategy.InvalidRanking.selector);
        strategy.castVote(PROPOSAL_ID, 1, voteData, 0);
    }

    function test_CastVoteAtVotingEndTimestampStillAllowed() public {
        _initializeProposalWithTwoSlates();
        uint48 votingEndTimestamp = strategy.proposalVotingDetails(PROPOSAL_ID).votingEndTimestamp;

        vm.warp(votingEndTimestamp);
        _castVote(alice, _ranking(1, 2, 0));

        assertEq(strategy.ballotCount(PROPOSAL_ID), 1);
        assertEq(strategy.proposalVotingDetails(PROPOSAL_ID).yesVotes, 4);
    }

    function test_FirstLateVoteMarksPeriodEndedAndSecondLateVoteReverts() public {
        _initializeProposalWithTwoSlates();
        vm.warp(strategy.proposalVotingDetails(PROPOSAL_ID).votingEndTimestamp + 1);

        vm.prank(alice);
        strategy.castVote(PROPOSAL_ID, 1, _voteData(_ranking(1, 2, 0)), 0);

        assertTrue(strategy.voteCastedAfterVotingPeriodEnded(PROPOSAL_ID));
        assertEq(strategy.ballotCount(PROPOSAL_ID), 0);
        assertEq(strategy.proposalVotingDetails(PROPOSAL_ID).yesVotes, 0);

        vm.prank(bob);
        vm.expectRevert(IStrategyV1.ProposalNotActive.selector);
        strategy.castVote(PROPOSAL_ID, 1, _voteData(_ranking(2, 1, 0)), 0);
    }

    function test_GetWinningSlateReturnsDefaultWhenOnlyDefaultSlateExists() public {
        strategy.initializeProposal(PROPOSAL_ID);

        (uint16 winner, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winner, 0);
        assertTrue(strategy.isBasisMet(PROPOSAL_ID));
    }

    function test_GetWinningSlateInstantMajority() public {
        _initializeProposalWithTwoSlates();

        _castVote(alice, _ranking(1, 2, 0));
        _castVote(bob, _ranking(1, 2, 0));
        _castVote(carol, _ranking(2, 1, 0));

        (uint16 winner, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winner, 1);
    }

    function test_GetWinningSlateEliminatesLowestAndTransfersPreferences() public {
        _initializeProposalWithThreeSlates();

        _castVote(alice, _ranking(1, 2, 3, 0));
        _castVote(bob, _ranking(2, 1, 3, 0));
        _castVote(carol, _ranking(3, 2, 1, 0));
        _castVote(dave, _ranking(3, 2, 1, 0));

        (uint16 winner, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winner, 2);
    }

    function test_GetWinningSlateFallsBackToDefaultOnFullTie() public {
        _initializeProposalWithTwoSlates();

        _castVote(alice, _ranking(1, 2, 0));
        _castVote(bob, _ranking(2, 1, 0));
        _castVote(carol, _ranking(0, 2, 1));
        _castVote(dave, _ranking(0, 1, 2));

        (uint16 winner, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winner, 0);
    }

    function test_GetWinningSlateAllowsDefaultToWinByRanking() public {
        _initializeProposalWithTwoSlates();

        _castVote(alice, _ranking(0, 1, 2));
        _castVote(bob, _ranking(0, 2, 1));
        _castVote(carol, _ranking(1, 0, 2));
        _castVote(dave, _ranking(2, 0, 1));

        (uint16 winner, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winner, 0);
    }

    function test_GetWinningSlateGasCrossesRepresentativeBlockLimit() public {
        uint16 lowerBound = 0;
        uint16 upperBound = 8;
        uint256 gasUsedAtUpperBound;

        while (true) {
            gasUsedAtUpperBound = _measureWinningSlateGasForStressProposal(upperBound);
            if (gasUsedAtUpperBound > REPRESENTATIVE_BLOCK_GAS_LIMIT) {
                break;
            }

            lowerBound = upperBound;
            upperBound *= 2;
            assertLe(upperBound, 512, "stress search did not cross representative block gas limit");
        }

        while (upperBound - lowerBound > 1) {
            uint16 midpoint = lowerBound + (upperBound - lowerBound) / 2;
            uint256 gasUsedAtMidpoint = _measureWinningSlateGasForStressProposal(midpoint);

            if (gasUsedAtMidpoint > REPRESENTATIVE_BLOCK_GAS_LIMIT) {
                upperBound = midpoint;
                gasUsedAtUpperBound = gasUsedAtMidpoint;
            } else {
                lowerBound = midpoint;
            }
        }

        emit log_named_uint("winning slate gas threshold slates", upperBound);
        emit log_named_uint("winning slate gas at threshold", gasUsedAtUpperBound);
        emit log_named_uint("representative block gas limit", REPRESENTATIVE_BLOCK_GAS_LIMIT);

        assertGt(gasUsedAtUpperBound, REPRESENTATIVE_BLOCK_GAS_LIMIT);
    }

    function test_IsBasisMetAndIsPassedFollowResolvedWinnerAndQuorum() public {
        _initializeProposalWithTwoSlates();

        _castVote(alice, _ranking(1, 2, 0));
        _castVote(bob, _ranking(1, 2, 0));

        assertTrue(strategy.isBasisMet(PROPOSAL_ID));
        assertFalse(strategy.isPassed(PROPOSAL_ID));

        vm.warp(strategy.proposalVotingDetails(PROPOSAL_ID).votingEndTimestamp + 1);

        assertTrue(strategy.isQuorumMet(PROPOSAL_ID));
        assertTrue(strategy.isPassed(PROPOSAL_ID));
    }

    function test_IsPassedReturnsFalseWhenQuorumNotMet() public {
        _initializeProposalWithTwoSlates();

        _castVote(dave, _ranking(1, 2, 0));

        vm.warp(strategy.proposalVotingDetails(PROPOSAL_ID).votingEndTimestamp + 1);

        assertTrue(strategy.isBasisMet(PROPOSAL_ID));
        assertFalse(strategy.isQuorumMet(PROPOSAL_ID));
        assertFalse(strategy.isPassed(PROPOSAL_ID));
    }

    function test_IsPassedReturnsTrueWhenDefaultSlateWinsAndQuorumIsMet() public {
        _initializeProposalWithTwoSlates();

        _castVote(alice, _ranking(0, 1, 2));
        _castVote(bob, _ranking(0, 2, 1));

        vm.warp(strategy.proposalVotingDetails(PROPOSAL_ID).votingEndTimestamp + 1);

        (uint16 winner, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winner, 0);
        assertTrue(strategy.isQuorumMet(PROPOSAL_ID));
        assertTrue(strategy.isPassed(PROPOSAL_ID));
    }

    function _initializeProposalWithTwoSlates() internal {
        _initializeProposalWithTwoSlates(strategy, PROPOSAL_ID);
    }

    function _initializeProposalWithTwoSlates(
        PENRankedChoiceStrategy target_,
        uint32 proposalId_
    ) internal {
        target_.initializeProposal(proposalId_);

        vm.prank(alice);
        target_.submitSlate(proposalId_, 1);
        vm.prank(bob);
        target_.submitSlate(proposalId_, 2);

        vm.warp(block.timestamp + 1);
    }

    function _initializeProposalWithThreeSlates() internal {
        strategy.initializeProposal(PROPOSAL_ID);

        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);
        vm.prank(bob);
        strategy.submitSlate(PROPOSAL_ID, 2);
        vm.prank(carol);
        strategy.submitSlate(PROPOSAL_ID, 3);

        vm.warp(block.timestamp + 1);
    }

    function _measureWinningSlateGasForStressProposal(
        uint16 slateCount_
    ) internal returns (uint256 gasUsed) {
        uint32 proposalId = nextStressProposalId++;
        _initializeStressProposal(proposalId, slateCount_);

        bool resolved;
        (gasUsed, , resolved) = gasProbe.measure(strategy, proposalId);
        assertTrue(resolved);
    }

    function _initializeStressProposal(uint32 proposalId_, uint16 slateCount_) internal {
        vm.warp(block.timestamp + 1);

        address[] memory voters = new address[](slateCount_);
        for (uint16 i = 0; i < slateCount_; ++i) {
            address voter = _stressVoter(proposalId_, i);
            voters[i] = voter;
            _mintSeats(voter, uint256(i) + 1);
        }

        vm.warp(block.timestamp + 1);
        strategy.initializeProposal(proposalId_);

        for (uint16 i = 0; i < slateCount_; ++i) {
            vm.prank(voters[i]);
            strategy.submitSlate(proposalId_, i + 1);
        }

        vm.warp(block.timestamp + 1);

        for (uint16 i = 0; i < slateCount_; ++i) {
            vm.prank(voters[i]);
            strategy.castVote(
                proposalId_,
                1,
                _voteData(_stressRanking(slateCount_, i + 1)),
                0
            );
        }
    }

    function _stressVoter(uint32 proposalId_, uint16 voterIndex_) internal pure returns (address) {
        return address(uint160((uint256(proposalId_) << 16) | uint256(voterIndex_) + 1));
    }

    function _mintSeats(address account, uint256 amount) internal {
        seatToken.mint(account, amount);
    }

    function _deployStrategyWithTwoVotingConfigs() internal returns (PENRankedChoiceStrategy deployed) {
        deployed = _deployStrategy();
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), address(deployed));

        VotingWeightERC20V1 weightOne = _deployVotingWeight();
        VotingWeightERC20V1 weightTwo = _deployVotingWeight();
        VoteTrackerERC20V1 trackerOne = _deployVoteTracker(address(deployed));
        VoteTrackerERC20V1 trackerTwo = _deployVoteTracker(address(deployed));

        IVotingTypes.VotingConfig[] memory votingConfigs = new IVotingTypes.VotingConfig[](2);
        votingConfigs[0] = IVotingTypes.VotingConfig({
            votingWeight: address(weightOne),
            voteTracker: address(trackerOne)
        });
        votingConfigs[1] = IVotingTypes.VotingConfig({
            votingWeight: address(weightTwo),
            voteTracker: address(trackerTwo)
        });

        deployed.initialize(VOTING_PERIOD, 6, 500_001, _singleAdapter(PROPOSER_ADAPTER), address(0));
        deployed.initialize2(address(this), votingConfigs);
    }

    function _deployStrategy() internal returns (PENRankedChoiceStrategy deployed) {
        PENRankedChoiceStrategy implementation = new PENRankedChoiceStrategy();
        deployed = PENRankedChoiceStrategy(Clones.clone(address(implementation)));
    }

    function _deployVotingWeight() internal returns (VotingWeightERC20V1 deployed) {
        VotingWeightERC20V1 implementation = new VotingWeightERC20V1();
        deployed = VotingWeightERC20V1(Clones.clone(address(implementation)));
        deployed.initialize(address(seatToken), 1);
    }

    function _deployVoteTracker(address authorizedCaller) internal returns (VoteTrackerERC20V1 deployed) {
        VoteTrackerERC20V1 implementation = new VoteTrackerERC20V1();
        deployed = VoteTrackerERC20V1(Clones.clone(address(implementation)));
        deployed.initialize(_singleAdapter(authorizedCaller));
    }

    function _castVote(address voter_, uint16[] memory ranking_) internal {
        vm.prank(voter_);
        strategy.castVote(PROPOSAL_ID, 1, _voteData(ranking_), 0);
    }

    function _voteData(
        uint16[] memory ranking_
    ) internal pure returns (IVotingTypes.VotingConfigVoteData[] memory votingConfigsData) {
        votingConfigsData = new IVotingTypes.VotingConfigVoteData[](1);
        votingConfigsData[0] = IVotingTypes.VotingConfigVoteData({
            configIndex: 0,
            voteData: abi.encode(ranking_)
        });
    }

    function _singleVotingConfig(
        address votingWeight_,
        address voteTracker_
    ) internal pure returns (IVotingTypes.VotingConfig[] memory votingConfigs) {
        votingConfigs = new IVotingTypes.VotingConfig[](1);
        votingConfigs[0] = IVotingTypes.VotingConfig({
            votingWeight: votingWeight_,
            voteTracker: voteTracker_
        });
    }

    function _singleAdapter(address adapter_) internal pure returns (address[] memory adapters) {
        adapters = new address[](1);
        adapters[0] = adapter_;
    }

    function _stressRanking(
        uint16 slateCount_,
        uint16 firstSlateId_
    ) internal pure returns (uint16[] memory ranking) {
        ranking = new uint16[](uint256(slateCount_) + 1);

        uint256 cursor;
        for (uint16 slateId = firstSlateId_; slateId <= slateCount_; ++slateId) {
            ranking[cursor] = slateId;
            unchecked {
                ++cursor;
            }
        }

        for (uint16 slateId = 1; slateId < firstSlateId_; ++slateId) {
            ranking[cursor] = slateId;
            unchecked {
                ++cursor;
            }
        }

        ranking[cursor] = 0;
    }

    function _ranking(uint16 first, uint16 second) internal pure returns (uint16[] memory ranking) {
        ranking = new uint16[](2);
        ranking[0] = first;
        ranking[1] = second;
    }

    function _ranking(uint16 first, uint16 second, uint16 third) internal pure returns (uint16[] memory ranking) {
        ranking = new uint16[](3);
        ranking[0] = first;
        ranking[1] = second;
        ranking[2] = third;
    }

    function _ranking(
        uint16 first,
        uint16 second,
        uint16 third,
        uint16 fourth
    ) internal pure returns (uint16[] memory ranking) {
        ranking = new uint16[](4);
        ranking[0] = first;
        ranking[1] = second;
        ranking[2] = third;
        ranking[3] = fourth;
    }
}
