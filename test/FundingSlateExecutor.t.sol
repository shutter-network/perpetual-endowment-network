// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {FundingSlateExecutor} from "../src/governance/FundingSlateExecutor.sol";
import {PENRankedChoiceStrategy} from "../src/governance/PENRankedChoiceStrategy.sol";

import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {VotingWeightERC20V1} from "decent-contracts/contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import {VoteTrackerERC20V1} from "decent-contracts/contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";

contract FundingSlateExecutorTest is Test {
    uint32 internal constant PROPOSAL_ID = 7;
    uint256 internal constant YIELD_AMOUNT = 1_000e18;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal nonHolder = makeAddr("nonHolder");
    address internal executor = makeAddr("executor");
    address internal recipientOne = makeAddr("recipientOne");
    address internal recipientTwo = makeAddr("recipientTwo");

    SeatToken internal seatToken;
    ERC20Mock internal asset;
    ERC4626Mock internal yieldVault;
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
        seatToken.mint(carol, 1);

        asset = new ERC20Mock();
        yieldVault = new ERC4626Mock(address(asset));

        strategy = _deployStrategy();
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), address(strategy));
        votingWeight = _deployVotingWeight();
        voteTracker = _deployVoteTracker();

        strategy.initialize(3 days, 2, 500_001, _singleAddress(address(this)), address(0));
        strategy.initialize2(address(this), _singleVotingConfig());

        fundingExecutor = new FundingSlateExecutor(
            asset,
            yieldVault,
            strategy,
            seatToken,
            address(this),
            executor
        );

        asset.mint(address(this), YIELD_AMOUNT);
        asset.approve(address(yieldVault), YIELD_AMOUNT);
        yieldVault.deposit(YIELD_AMOUNT, address(fundingExecutor));
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

    function test_OnlyExecutorCanExecuteFunding() public {
        _configureWinningSlate();

        vm.startPrank(nonHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonHolder,
                fundingExecutor.EXECUTOR_ROLE()
            )
        );
        fundingExecutor.executeFunding(PROPOSAL_ID);
        vm.stopPrank();
    }

    function test_ExecuteFundingDistributesWinningSlate() public {
        _configureWinningSlate();

        vm.prank(executor);
        (uint16 winningSlate, uint256 distributedAmount) = fundingExecutor.executeFunding(PROPOSAL_ID);

        assertEq(winningSlate, 2);
        assertEq(distributedAmount, YIELD_AMOUNT);
        assertEq(asset.balanceOf(recipientOne), 300e18);
        assertEq(asset.balanceOf(recipientTwo), 700e18);
        assertEq(yieldVault.balanceOf(address(fundingExecutor)), 0);
    }

    function _configureWinningSlate() internal {
        strategy.initializeProposal(PROPOSAL_ID);

        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);
        vm.prank(alice);
        fundingExecutor.registerSlate(
            PROPOSAL_ID,
            1,
            _recipients(recipientOne, recipientTwo),
            _amounts(600e18, 400e18)
        );

        vm.prank(bob);
        strategy.submitSlate(PROPOSAL_ID, 2);
        vm.prank(bob);
        fundingExecutor.registerSlate(
            PROPOSAL_ID,
            2,
            _recipients(recipientOne, recipientTwo),
            _amounts(300e18, 700e18)
        );

        vm.warp(block.timestamp + 1);
        _castVote(alice, _ranking(1, 2, 0));
        _castVote(bob, _ranking(2, 1, 0));
        _castVote(carol, _ranking(2, 0, 1));

        (uint16 winner, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winner, 2);
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

    function _ranking(uint16 first, uint16 second, uint16 third) internal pure returns (uint16[] memory ranking) {
        ranking = new uint16[](3);
        ranking[0] = first;
        ranking[1] = second;
        ranking[2] = third;
    }
}
