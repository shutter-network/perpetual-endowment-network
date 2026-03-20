// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {FundingSlateExecutor} from "../src/governance/FundingSlateExecutor.sol";
import {PENRankedChoiceStrategy} from "../src/governance/PENRankedChoiceStrategy.sol";

import {Transaction} from "decent-contracts/contracts/interfaces/decent/Module.sol";
import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {IModuleAzoriusV1} from "decent-contracts/contracts/interfaces/decent/deployables/IModuleAzoriusV1.sol";
import {ModuleAzoriusV1} from "decent-contracts/contracts/deployables/modules/ModuleAzoriusV1.sol";
import {VotingWeightERC20V1} from "decent-contracts/contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import {VoteTrackerERC20V1} from "decent-contracts/contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";
import {ProposerAdapterERC20V1} from "decent-contracts/contracts/deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol";
import {MockAvatar} from "decent-contracts/contracts/mocks/MockAvatar.sol";

contract FundingCycleIntegrationTest is Test {
    uint32 internal constant YIELD_PROPOSAL_ID = 0;
    uint32 internal constant FUNDING_PROPOSAL_ID = 1;
    uint32 internal constant VOTING_PERIOD = 3 days;
    uint32 internal constant TIMELOCK_PERIOD = 1 days;
    uint32 internal constant EXECUTION_PERIOD = 2 days;

    uint256 internal constant PRINCIPAL_AMOUNT = 10_000e18;
    uint256 internal constant GENERATED_YIELD = 1_000e18;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");

    address internal grantOne = makeAddr("grantOne");
    address internal grantTwo = makeAddr("grantTwo");

    SeatToken internal seatToken;
    ERC20Mock internal asset;
    ERC4626Mock internal principalVault;
    ERC4626Mock internal yieldVault;
    PrincipalManager internal principalManager;
    PENRankedChoiceStrategy internal strategy;
    ModuleAzoriusV1 internal azorius;
    VotingWeightERC20V1 internal votingWeight;
    VoteTrackerERC20V1 internal voteTracker;
    ProposerAdapterERC20V1 internal proposerAdapter;
    MockAvatar internal avatar;
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

        _mintSeat(alice);
        _mintSeat(bob);
        _mintSeat(carol);
        _mintSeat(dave);
        _mintSeat(eve);

        asset = new ERC20Mock();
        principalVault = new ERC4626Mock(address(asset));
        yieldVault = new ERC4626Mock(address(asset));
        avatar = new MockAvatar();

        principalManager = new PrincipalManager(asset, address(this), address(this), address(0), 0);
        principalManager.setPrincipalVault(principalVault);

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

        principalManager.setYieldVault(yieldVault, address(fundingExecutor));
        principalManager.grantRole(principalManager.DEFAULT_ADMIN_ROLE(), address(avatar));

        azorius = _deployAzorius();
        avatar.enableModule(address(azorius));

        strategy.initialize(
            VOTING_PERIOD,
            5,
            500_001,
            _singleAddress(address(proposerAdapter)),
            address(0)
        );
        strategy.initialize2(address(azorius), _singleVotingConfig());

        asset.mint(address(principalManager), PRINCIPAL_AMOUNT);
        principalManager.recordPurchase(PRINCIPAL_AMOUNT);
    }

    function test_FundingCycleHappyPath() public {
        uint48 aliceInitialActivity = seatToken.lastActivityAt(alice);
        uint48 bobInitialActivity = seatToken.lastActivityAt(bob);
        uint48 carolInitialActivity = seatToken.lastActivityAt(carol);
        uint48 daveInitialActivity = seatToken.lastActivityAt(dave);
        uint48 eveInitialActivity = seatToken.lastActivityAt(eve);

        assertEq(principalManager.accountedPrincipal(), PRINCIPAL_AMOUNT);
        assertEq(principalManager.deployedAssets(), PRINCIPAL_AMOUNT);
        assertEq(principalManager.availableYield(), 0);

        vm.warp(block.timestamp + 366 days);
        assertEq(principalManager.availableYield(), 0);

        asset.mint(address(principalVault), GENERATED_YIELD);
        uint256 measuredYield = principalManager.availableYield();
        assertGt(measuredYield, 0);
        assertLe(measuredYield, GENERATED_YIELD);

        Transaction[] memory yieldTransferTxs = new Transaction[](1);
        yieldTransferTxs[0] = Transaction({
            to: address(principalManager),
            value: 0,
            data: abi.encodeCall(PrincipalManager.transferYieldToVault, (measuredYield)),
            operation: Enum.Operation.Call
        });

        vm.prank(alice);
        azorius.submitProposal(
            yieldTransferTxs,
            "ipfs://pen-proposal/transfer-yield",
            address(proposerAdapter),
            ""
        );

        vm.prank(alice);
        strategy.submitSlate(YIELD_PROPOSAL_ID, 1);

        vm.warp(block.timestamp + 1);
        _castVote(YIELD_PROPOSAL_ID, alice, _ranking(1, 0));
        _castVote(YIELD_PROPOSAL_ID, bob, _ranking(1, 0));
        _castVote(YIELD_PROPOSAL_ID, carol, _ranking(1, 0));
        _castVote(YIELD_PROPOSAL_ID, dave, _ranking(1, 0));
        _castVote(YIELD_PROPOSAL_ID, eve, _ranking(1, 0));

        _advanceToExecutable(YIELD_PROPOSAL_ID);
        azorius.executeProposal(YIELD_PROPOSAL_ID, yieldTransferTxs);

        assertEq(principalManager.accountedPrincipal(), PRINCIPAL_AMOUNT);
        assertEq(principalManager.availableYield(), 0);
        assertEq(principalManager.deployedAssets(), PRINCIPAL_AMOUNT);
        assertGt(yieldVault.balanceOf(address(fundingExecutor)), 0);

        Transaction[] memory fundingTxs = new Transaction[](1);
        fundingTxs[0] = Transaction({
            to: address(fundingExecutor),
            value: 0,
            data: abi.encodeCall(FundingSlateExecutor.executeFunding, (FUNDING_PROPOSAL_ID)),
            operation: Enum.Operation.Call
        });

        vm.prank(alice);
        azorius.submitProposal(
            fundingTxs,
            "ipfs://pen-proposal/funding-cycle",
            address(proposerAdapter),
            ""
        );

        vm.prank(alice);
        strategy.submitSlate(FUNDING_PROPOSAL_ID, 1);
        uint256 slateOneGrant = (measuredYield * 60) / 100;
        uint256 slateOneReserve = measuredYield - slateOneGrant;
        vm.prank(alice);
        fundingExecutor.registerSlate(
            FUNDING_PROPOSAL_ID,
            1,
            _recipients(grantOne, grantTwo),
            _amounts(slateOneGrant, slateOneReserve)
        );

        vm.prank(bob);
        strategy.submitSlate(FUNDING_PROPOSAL_ID, 2);
        uint256 slateTwoGrant = (measuredYield * 30) / 100;
        uint256 slateTwoReserve = measuredYield - slateTwoGrant;
        vm.prank(bob);
        fundingExecutor.registerSlate(
            FUNDING_PROPOSAL_ID,
            2,
            _recipients(grantOne, grantTwo),
            _amounts(slateTwoGrant, slateTwoReserve)
        );

        vm.warp(block.timestamp + 1);
        _castVote(FUNDING_PROPOSAL_ID, alice, _ranking(1, 2, 0));
        _castVote(FUNDING_PROPOSAL_ID, bob, _ranking(2, 1, 0));
        _castVote(FUNDING_PROPOSAL_ID, carol, _ranking(2, 1, 0));
        _castVote(FUNDING_PROPOSAL_ID, dave, _ranking(0, 2, 1));
        _castVote(FUNDING_PROPOSAL_ID, eve, _ranking(2, 0, 1));

        (uint16 winner, bool resolved) = strategy.getWinningSlate(FUNDING_PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winner, 2);

        _advanceToExecutable(FUNDING_PROPOSAL_ID);
        azorius.executeProposal(FUNDING_PROPOSAL_ID, fundingTxs);

        assertEq(asset.balanceOf(grantOne), slateTwoGrant);
        assertEq(asset.balanceOf(grantTwo), slateTwoReserve);
        assertEq(yieldVault.balanceOf(address(fundingExecutor)), 0);
        assertEq(principalManager.accountedPrincipal(), PRINCIPAL_AMOUNT);
        assertEq(principalManager.deployedAssets(), PRINCIPAL_AMOUNT);
        assertEq(principalManager.availableYield(), 0);

        assertGt(seatToken.lastActivityAt(alice), aliceInitialActivity);
        assertGt(seatToken.lastActivityAt(bob), bobInitialActivity);
        assertGt(seatToken.lastActivityAt(carol), carolInitialActivity);
        assertGt(seatToken.lastActivityAt(dave), daveInitialActivity);
        assertGt(seatToken.lastActivityAt(eve), eveInitialActivity);
    }

    function _mintSeat(address account) internal {
        seatToken.mint(account, 1);
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

    function _advanceToExecutable(uint32 proposalId_) internal {
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(proposalId_)), uint8(IModuleAzoriusV1.ProposalState.TIMELOCKED));

        vm.warp(block.timestamp + TIMELOCK_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(proposalId_)), uint8(IModuleAzoriusV1.ProposalState.EXECUTABLE));
    }

    function _castVote(uint32 proposalId_, address voter_, uint16[] memory ranking_) internal {
        vm.prank(voter_);
        strategy.castVote(proposalId_, 1, _voteData(ranking_), 0);
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

    function _ranking(uint16 first, uint16 second) internal pure returns (uint16[] memory ranking) {
        ranking = new uint16[](2);
        ranking[0] = first;
        ranking[1] = second;
    }

    function _ranking(
        uint16 first,
        uint16 second,
        uint16 third
    ) internal pure returns (uint16[] memory ranking) {
        ranking = new uint16[](3);
        ranking[0] = first;
        ranking[1] = second;
        ranking[2] = third;
    }
}
