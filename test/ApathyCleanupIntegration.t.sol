// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {PENRankedChoiceStrategy} from "../src/governance/PENRankedChoiceStrategy.sol";

import {Transaction} from "decent-contracts/contracts/interfaces/decent/Module.sol";
import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {IModuleAzoriusV1} from "decent-contracts/contracts/interfaces/decent/deployables/IModuleAzoriusV1.sol";
import {ModuleAzoriusV1} from "decent-contracts/contracts/deployables/modules/ModuleAzoriusV1.sol";
import {VotingWeightERC20V1} from "decent-contracts/contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import {VoteTrackerERC20V1} from "decent-contracts/contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";
import {ProposerAdapterERC20V1} from "decent-contracts/contracts/deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol";
import {MockAvatar} from "decent-contracts/contracts/mocks/MockAvatar.sol";

contract ApathyCleanupIntegrationTest is Test {
    uint32 internal constant INITIAL_PROPOSAL_ID = 0;
    uint32 internal constant CLEANUP_PROPOSAL_ID = 1;
    uint32 internal constant VOTING_PERIOD = 3 days;
    uint32 internal constant TIMELOCK_PERIOD = 1 days;
    uint32 internal constant EXECUTION_PERIOD = 2 days;
    uint256 internal constant MEMBER_SEATS = 100;
    uint256 internal constant MEMBER_COUNT = 10;
    uint256 internal constant TOTAL_SEATS = MEMBER_SEATS * MEMBER_COUNT;
    uint48 internal constant INACTIVITY_PERIOD = 365 days;

    address internal admin = makeAddr("admin");
    address internal reclaimer = makeAddr("reclaimer");
    address[10] internal members;

    SeatToken internal seatToken;
    ERC20Mock internal asset;
    PrincipalManager internal principalManager;
    BondingTranche internal bondingTranche;
    PENRankedChoiceStrategy internal strategy;
    ModuleAzoriusV1 internal azorius;
    VotingWeightERC20V1 internal votingWeight;
    VoteTrackerERC20V1 internal voteTracker;
    ProposerAdapterERC20V1 internal proposerAdapter;
    MockAvatar internal avatar;

    function setUp() public {
        members[0] = makeAddr("alice");
        members[1] = makeAddr("bob");
        members[2] = makeAddr("carol");
        members[3] = makeAddr("dave");
        members[4] = makeAddr("erin");
        members[5] = makeAddr("frank");
        members[6] = makeAddr("grace");
        members[7] = makeAddr("heidi");
        members[8] = makeAddr("ivan");
        members[9] = makeAddr("judy");

        seatToken = new SeatToken(
            "PEN Seat",
            "SEAT",
            TOTAL_SEATS,
            INACTIVITY_PERIOD,
            address(this),
            address(this),
            address(0),
            address(0)
        );

        for (uint256 i; i < MEMBER_COUNT; ++i) {
            seatToken.mint(members[i], MEMBER_SEATS);
        }

        asset = new ERC20Mock();
        avatar = new MockAvatar();
        principalManager = new PrincipalManager(asset, address(avatar), address(0), address(0), 100);

        uint256[] memory upperBounds = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        upperBounds[0] = TOTAL_SEATS;
        prices[0] = 1;
        bondingTranche = new BondingTranche(seatToken, principalManager, 1, admin, reclaimer, upperBounds, prices);

        vm.prank(address(this));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));

        strategy = _deployStrategy();
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), address(strategy));
        votingWeight = _deployVotingWeight();
        voteTracker = _deployVoteTracker(address(strategy));
        proposerAdapter = _deployProposerAdapter();
        azorius = _deployAzorius();

        avatar.enableModule(address(azorius));

        strategy.initialize(
            VOTING_PERIOD,
            MEMBER_SEATS,
            500_001,
            _singleAddress(address(proposerAdapter)),
            address(0)
        );
        strategy.initialize2(address(azorius), _singleVotingConfig());
    }

    function test_ApathyCleanupLeavesOneActiveMemberAndGovernanceContinues() public {
        assertEq(seatToken.totalSupply(), TOTAL_SEATS);

        vm.warp(block.timestamp + 40 days);
        _submitProposalAndVote(
            INITIAL_PROPOSAL_ID,
            150,
            members[0],
            _ranking(1, 0)
        );

        uint48 activeMemberTimestamp = seatToken.lastActivityAt(members[0]);
        assertEq(activeMemberTimestamp, block.timestamp);

        vm.warp(block.timestamp + 355 days);

        assertFalse(seatToken.isInactive(members[0]));
        for (uint256 i = 1; i < MEMBER_COUNT; ++i) {
            assertTrue(seatToken.isInactive(members[i]));
        }

        for (uint256 i = 1; i < MEMBER_COUNT; ++i) {
            vm.prank(reclaimer);
            uint256 reclaimedSeats = bondingTranche.reclaim(members[i]);
            assertEq(reclaimedSeats, MEMBER_SEATS);
            assertEq(seatToken.balanceOf(members[i]), 0);
        }

        assertEq(seatToken.totalSupply(), MEMBER_SEATS);
        assertEq(seatToken.balanceOf(members[0]), MEMBER_SEATS);
        assertEq(seatToken.getVotes(members[0]), MEMBER_SEATS);

        _submitProposalAndVote(
            CLEANUP_PROPOSAL_ID,
            250,
            members[0],
            _ranking(1, 0)
        );

        assertEq(uint8(azorius.proposalState(CLEANUP_PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.ACTIVE));
        assertTrue(strategy.isQuorumMet(CLEANUP_PROPOSAL_ID));

        _advanceToExecutable(CLEANUP_PROPOSAL_ID);
        assertTrue(strategy.isPassed(CLEANUP_PROPOSAL_ID));

        Transaction[] memory transactions = _setReserveTransactions(250);
        azorius.executeProposal(CLEANUP_PROPOSAL_ID, transactions);

        assertEq(principalManager.liquidReserveTarget(), 250);
        assertEq(uint8(azorius.proposalState(CLEANUP_PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.EXECUTED));
    }

    function _submitProposalAndVote(
        uint32 proposalId_,
        uint256 newReserveTarget_,
        address proposer_,
        uint16[] memory ranking_
    ) internal {
        Transaction[] memory transactions = _setReserveTransactions(newReserveTarget_);

        vm.prank(proposer_);
        azorius.submitProposal(
            transactions,
            "ipfs://pen-proposal/cleanup",
            address(proposerAdapter),
            ""
        );

        vm.prank(proposer_);
        strategy.submitSlate(proposalId_, 1);

        vm.warp(block.timestamp + 1);
        vm.prank(proposer_);
        strategy.castVote(proposalId_, 1, _voteData(ranking_), 0);
    }

    function _setReserveTransactions(uint256 newReserveTarget_) internal view returns (Transaction[] memory transactions) {
        transactions = new Transaction[](1);
        transactions[0] = Transaction({
            to: address(principalManager),
            value: 0,
            data: abi.encodeCall(PrincipalManager.setLiquidReserveTarget, (newReserveTarget_)),
            operation: Enum.Operation.Call
        });
    }

    function _advanceToExecutable(uint32 proposalId_) internal {
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(proposalId_)), uint8(IModuleAzoriusV1.ProposalState.TIMELOCKED));

        vm.warp(block.timestamp + TIMELOCK_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(proposalId_)), uint8(IModuleAzoriusV1.ProposalState.EXECUTABLE));
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
        deployed.initialize(_singleAddress(authorizedCaller));
    }

    function _deployProposerAdapter() internal returns (ProposerAdapterERC20V1 deployed) {
        ProposerAdapterERC20V1 implementation = new ProposerAdapterERC20V1();
        deployed = ProposerAdapterERC20V1(Clones.clone(address(implementation)));
        deployed.initialize(address(seatToken), 1);
    }

    function _deployAzorius() internal returns (ModuleAzoriusV1 deployed) {
        ModuleAzoriusV1 implementation = new ModuleAzoriusV1();
        deployed = ModuleAzoriusV1(Clones.clone(address(implementation)));
        deployed.initialize(
            address(this),
            address(avatar),
            address(avatar),
            address(strategy),
            TIMELOCK_PERIOD,
            EXECUTION_PERIOD
        );
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

    function _singleAddress(address item_) internal pure returns (address[] memory items) {
        items = new address[](1);
        items[0] = item_;
    }

    function _singleVotingConfig()
        internal
        view
        returns (IVotingTypes.VotingConfig[] memory votingConfigs)
    {
        votingConfigs = new IVotingTypes.VotingConfig[](1);
        votingConfigs[0] = IVotingTypes.VotingConfig({
            votingWeight: address(votingWeight),
            voteTracker: address(voteTracker)
        });
    }

    function _ranking(uint16 first, uint16 second) internal pure returns (uint16[] memory ranking) {
        ranking = new uint16[](2);
        ranking[0] = first;
        ranking[1] = second;
    }
}
