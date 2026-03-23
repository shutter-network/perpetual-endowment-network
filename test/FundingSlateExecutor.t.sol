// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {FundingSlateExecutor} from "../src/governance/FundingSlateExecutor.sol";
import {PENRankedChoiceStrategy} from "../src/governance/PENRankedChoiceStrategy.sol";

import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {VotingWeightERC20V1} from "decent-contracts/contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import {VoteTrackerERC20V1} from "decent-contracts/contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";

contract FundingSlateExecutorTest is Test {
    uint32 internal constant PROPOSAL_ID = 7;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal nonHolder = makeAddr("nonHolder");
    address internal recipientOne = makeAddr("recipientOne");
    address internal recipientTwo = makeAddr("recipientTwo");

    SeatToken internal seatToken;
    PENRankedChoiceStrategy internal strategy;
    VotingWeightERC20V1 internal votingWeight;
    VoteTrackerERC20V1 internal voteTracker;
    FundingSlateExecutor internal fundingExecutor;

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

        seatToken.mint(alice, 1);
        seatToken.mint(bob, 1);

        strategy = _deployStrategy();
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), address(strategy));
        votingWeight = _deployVotingWeight();
        voteTracker = _deployVoteTracker();

        strategy.initialize(3 days, 2, 500_001, _singleAddress(address(this)), address(0));
        strategy.initialize2(address(this), _singleVotingConfig());

        fundingExecutor = new FundingSlateExecutor(strategy, seatToken);
    }

    function test_RegisterSlateRevertsForNonHolder() public {
        strategy.initializeProposal(PROPOSAL_ID);
        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);

        vm.prank(nonHolder);
        vm.expectRevert(
            abi.encodeWithSelector(FundingSlateExecutor.NotSeatHolder.selector, nonHolder)
        );
        fundingExecutor.registerSlate(
            PROPOSAL_ID,
            1,
            _recipients(recipientOne, recipientTwo),
            _amounts(500e18, 500e18)
        );
    }

    function test_RegisterSlateStoresConfiguredRecipientsAndAmounts() public {
        strategy.initializeProposal(PROPOSAL_ID);
        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);

        vm.prank(alice);
        fundingExecutor.registerSlate(
            PROPOSAL_ID,
            1,
            _recipients(recipientOne, recipientTwo),
            _amounts(500e18, 500e18)
        );

        (address[] memory recipients, uint256[] memory amounts, uint256 totalAmount, bool exists) =
            fundingExecutor.slateOf(PROPOSAL_ID, 1);

        assertTrue(exists);
        assertEq(totalAmount, 1_000e18);
        assertEq(recipients.length, 2);
        assertEq(recipients[0], recipientOne);
        assertEq(recipients[1], recipientTwo);
        assertEq(amounts[0], 500e18);
        assertEq(amounts[1], 500e18);
    }

    function test_RevertWhenSlateIsUnknownToStrategy() public {
        strategy.initializeProposal(PROPOSAL_ID);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(FundingSlateExecutor.InvalidSlate.selector, uint16(1))
        );
        fundingExecutor.registerSlate(
            PROPOSAL_ID,
            1,
            _recipients(recipientOne, recipientTwo),
            _amounts(500e18, 500e18)
        );
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

    function _deployVoteTracker() internal returns (VoteTrackerERC20V1 deployed) {
        VoteTrackerERC20V1 implementation = new VoteTrackerERC20V1();
        deployed = VoteTrackerERC20V1(Clones.clone(address(implementation)));
        deployed.initialize(_singleAddress(address(strategy)));
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

    function _recipients(address first, address second) internal pure returns (address[] memory recipients) {
        recipients = new address[](2);
        recipients[0] = first;
        recipients[1] = second;
    }

    function _amounts(uint256 first, uint256 second) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = first;
        amounts[1] = second;
    }
}
