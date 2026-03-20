// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {FundingSlateExecutor} from "../src/governance/FundingSlateExecutor.sol";
import {PENRankedChoiceStrategy} from "../src/governance/PENRankedChoiceStrategy.sol";

import {Transaction} from "decent-contracts/contracts/interfaces/decent/Module.sol";
import {IStrategyV1} from "decent-contracts/contracts/interfaces/decent/deployables/IStrategyV1.sol";
import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {IModuleAzoriusV1} from "decent-contracts/contracts/interfaces/decent/deployables/IModuleAzoriusV1.sol";
import {ModuleAzoriusV1} from "decent-contracts/contracts/deployables/modules/ModuleAzoriusV1.sol";
import {VotingWeightERC20V1} from "decent-contracts/contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import {VoteTrackerERC20V1} from "decent-contracts/contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";
import {ProposerAdapterERC20V1} from "decent-contracts/contracts/deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol";
import {MockAvatar} from "decent-contracts/contracts/mocks/MockAvatar.sol";

contract InstantRunoffIntegrationTest is Test {
    uint32 internal constant PROPOSAL_ID = 0;
    uint32 internal constant VOTING_PERIOD = 3 days;
    uint32 internal constant TIMELOCK_PERIOD = 1 days;
    uint32 internal constant EXECUTION_PERIOD = 2 days;
    uint256 internal constant DISTRIBUTION_AMOUNT = 1_000e18;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal slateARecipient = makeAddr("slateARecipient");
    address internal slateBRecipient = makeAddr("slateBRecipient");
    address internal slateCRecipient = makeAddr("slateCRecipient");

    SeatToken internal seatToken;
    ERC20Mock internal asset;
    ERC4626Mock internal yieldVault;
    FundingSlateExecutor internal fundingExecutor;
    PENRankedChoiceStrategy internal strategy;
    ModuleAzoriusV1 internal azorius;
    VotingWeightERC20V1 internal votingWeight;
    VoteTrackerERC20V1 internal voteTracker;
    ProposerAdapterERC20V1 internal proposerAdapter;
    MockAvatar internal avatar;

    function setUp() public {
        seatToken = new SeatToken(
            "PEN Seat",
            "SEAT",
            100,
            365 days,
            address(this),
            address(this),
            address(this),
            address(0)
        );

        seatToken.mint(alice, 40);
        seatToken.mint(bob, 35);
        seatToken.mint(carol, 25);

        vm.warp(block.timestamp + 1);

        asset = new ERC20Mock();
        yieldVault = new ERC4626Mock(address(asset));
        avatar = new MockAvatar();

        strategy = _deployStrategy();
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), address(strategy));
        votingWeight = _deployVotingWeight();
        voteTracker = _deployVoteTracker(address(strategy));
        proposerAdapter = _deployProposerAdapter();

        fundingExecutor = new FundingSlateExecutor(
            asset,
            yieldVault,
            strategy,
            seatToken,
            address(this),
            address(avatar)
        );

        azorius = _deployAzorius();
        avatar.enableModule(address(azorius));

        strategy.initialize(
            VOTING_PERIOD,
            51,
            500_001,
            _singleAddress(address(proposerAdapter)),
            address(0)
        );
        strategy.initialize2(address(azorius), _singleVotingConfig());

        asset.mint(address(this), DISTRIBUTION_AMOUNT);
        asset.approve(address(yieldVault), DISTRIBUTION_AMOUNT);
        yieldVault.deposit(DISTRIBUTION_AMOUNT, address(fundingExecutor));
    }

    function test_InstantRunoffEliminatesLowestSlateAndAzoriusExecutesWinner() public {
        Transaction[] memory fundingTxs = new Transaction[](1);
        fundingTxs[0] = Transaction({
            to: address(fundingExecutor),
            value: 0,
            data: abi.encodeCall(FundingSlateExecutor.executeFunding, (PROPOSAL_ID)),
            operation: Enum.Operation.Call
        });

        vm.prank(alice);
        azorius.submitProposal(
            fundingTxs,
            "ipfs://pen-proposal/instant-runoff",
            address(proposerAdapter),
            ""
        );

        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);
        vm.prank(bob);
        strategy.submitSlate(PROPOSAL_ID, 2);
        vm.prank(carol);
        strategy.submitSlate(PROPOSAL_ID, 3);

        vm.prank(alice);
        fundingExecutor.registerSlate(
            PROPOSAL_ID,
            1,
            _singleRecipient(slateARecipient),
            _singleAmount(DISTRIBUTION_AMOUNT)
        );

        vm.prank(bob);
        fundingExecutor.registerSlate(
            PROPOSAL_ID,
            2,
            _singleRecipient(slateBRecipient),
            _singleAmount(DISTRIBUTION_AMOUNT)
        );

        vm.prank(carol);
        fundingExecutor.registerSlate(
            PROPOSAL_ID,
            3,
            _singleRecipient(slateCRecipient),
            _singleAmount(DISTRIBUTION_AMOUNT)
        );

        vm.warp(block.timestamp + 1);

        _castVote(alice, _ranking(1, 2, 3, 0));
        _castVote(bob, _ranking(2, 3, 1, 0));
        _castVote(carol, _ranking(3, 2, 1, 0));

        IStrategyV1.ProposalVotingDetails memory details = strategy.proposalVotingDetails(PROPOSAL_ID);
        assertEq(details.yesVotes, 100);
        assertTrue(strategy.isQuorumMet(PROPOSAL_ID));

        (uint16 winningSlate, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winningSlate, 2);

        _advanceToExecutable(PROPOSAL_ID);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.EXECUTABLE));

        azorius.executeProposal(PROPOSAL_ID, fundingTxs);

        assertEq(asset.balanceOf(slateARecipient), 0);
        assertEq(asset.balanceOf(slateBRecipient), DISTRIBUTION_AMOUNT);
        assertEq(asset.balanceOf(slateCRecipient), 0);
        assertEq(yieldVault.balanceOf(address(fundingExecutor)), 0);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.EXECUTED));
    }

    function _advanceToExecutable(uint32 proposalId_) internal {
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(proposalId_)), uint8(IModuleAzoriusV1.ProposalState.TIMELOCKED));

        vm.warp(block.timestamp + TIMELOCK_PERIOD + 1);
    }

    function _castVote(address voter_, uint16[] memory ranking_) internal {
        vm.prank(voter_);
        strategy.castVote(PROPOSAL_ID, 1, _voteData(ranking_), 0);
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

    function _singleAddress(address item_) internal pure returns (address[] memory items) {
        items = new address[](1);
        items[0] = item_;
    }

    function _singleRecipient(address recipient_) internal pure returns (address[] memory recipients) {
        recipients = new address[](1);
        recipients[0] = recipient_;
    }

    function _singleAmount(uint256 amount_) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount_;
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
