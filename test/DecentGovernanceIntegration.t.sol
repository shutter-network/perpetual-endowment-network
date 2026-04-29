// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {PENStrategyV1} from "../src/governance/PENStrategyV1.sol";

import {Transaction} from "decent-contracts/contracts/interfaces/decent/Module.sol";
import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {IModuleAzoriusV1} from "decent-contracts/contracts/interfaces/decent/deployables/IModuleAzoriusV1.sol";
import {IStrategyV1} from "decent-contracts/contracts/interfaces/decent/deployables/IStrategyV1.sol";
import {ModuleAzoriusV1} from "decent-contracts/contracts/deployables/modules/ModuleAzoriusV1.sol";
import {VotingWeightERC20V1} from "decent-contracts/contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import {VoteTrackerERC20V1} from "decent-contracts/contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";
import {ProposerAdapterERC20V1} from "decent-contracts/contracts/deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol";
import {MockAvatar} from "decent-contracts/contracts/mocks/MockAvatar.sol";

contract DecentGovernanceIntegrationTest is Test {
    uint32 internal constant PROPOSAL_ID = 0;
    uint32 internal constant VOTING_PERIOD = 3 days;
    uint32 internal constant TIMELOCK_PERIOD = 1 days;
    uint32 internal constant EXECUTION_PERIOD = 2 days;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    SeatToken internal seatToken;
    ERC20Mock internal asset;
    PrincipalManager internal principalManager;
    PENStrategyV1 internal strategy;
    ModuleAzoriusV1 internal azorius;
    VotingWeightERC20V1 internal votingWeight;
    VoteTrackerERC20V1 internal voteTracker;
    ProposerAdapterERC20V1 internal proposerAdapter;
    MockAvatar internal avatar;

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

        seatToken.mint(alice, 4);
        seatToken.mint(bob, 3);
        seatToken.mint(carol, 2);
        seatToken.mint(dave, 1);

        vm.warp(block.timestamp + 1);

        avatar = new MockAvatar();
        asset = new ERC20Mock();
        principalManager = new PrincipalManager(
            asset,
            address(avatar),
            address(0),
            100,
            IERC4626(address(0))
        );

        strategy = _deployStrategy();
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), address(strategy));
        votingWeight = _deployVotingWeight();
        voteTracker = _deployVoteTracker(address(strategy));
        proposerAdapter = _deployProposerAdapter();
        azorius = _deployAzorius();

        avatar.enableModule(address(azorius));

        strategy.initialize(
            VOTING_PERIOD,
            6,
            500_001,
            _singleAddress(address(proposerAdapter)),
            address(0)
        );
        strategy.initialize2(address(azorius), _singleVotingConfig());
    }

    function test_EndToEndProposalLifecycleExecutesAgainstPrincipalManager() public {
        assertEq(principalManager.liquidReserveTarget(), 100);

        Transaction[] memory transactions = new Transaction[](1);
        transactions[0] = Transaction({
            to: address(principalManager),
            value: 0,
            data: abi.encodeCall(PrincipalManager.setLiquidReserveTarget, (250)),
            operation: Enum.Operation.Call
        });

        vm.prank(alice);
        azorius.submitProposal(
            transactions,
            "ipfs://pen-proposal/liquid-reserve-update",
            address(proposerAdapter),
            ""
        );

        assertEq(azorius.totalProposalCount(), 1);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.ACTIVE));

        vm.warp(block.timestamp + 1);

        _castYes(alice);
        _castYes(bob);
        _castYes(carol);
        _castYes(dave);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.TIMELOCKED));

        vm.warp(block.timestamp + TIMELOCK_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.EXECUTABLE));

        azorius.executeProposal(PROPOSAL_ID, transactions);

        assertEq(principalManager.liquidReserveTarget(), 250);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.EXECUTED));
    }

    function _deployStrategy() internal returns (PENStrategyV1 deployed) {
        PENStrategyV1 implementation = new PENStrategyV1();
        deployed = PENStrategyV1(Clones.clone(address(implementation)));
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

    function _castYes(address voter) internal {
        vm.prank(voter);
        strategy.castVote(PROPOSAL_ID, uint8(IStrategyV1.VoteType.YES), _voteData(), 0);
    }

    function _voteData() internal pure returns (IVotingTypes.VotingConfigVoteData[] memory votingConfigsData) {
        votingConfigsData = new IVotingTypes.VotingConfigVoteData[](1);
        votingConfigsData[0] = IVotingTypes.VotingConfigVoteData({
            configIndex: 0,
            voteData: ""
        });
    }

    function _singleAddress(address item) internal pure returns (address[] memory items) {
        items = new address[](1);
        items[0] = item;
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

}
