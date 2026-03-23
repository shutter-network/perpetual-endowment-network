// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {PENRankedChoiceStrategy} from "../src/governance/PENRankedChoiceStrategy.sol";
import {PENDeploymentHelper} from "../script/PENDeploymentScriptBase.s.sol";

import {Transaction} from "decent-contracts/contracts/interfaces/decent/Module.sol";
import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {IModuleAzoriusV1} from "decent-contracts/contracts/interfaces/decent/deployables/IModuleAzoriusV1.sol";
import {ModuleAzoriusV1} from "decent-contracts/contracts/deployables/modules/ModuleAzoriusV1.sol";
import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";

contract PENScriptedDeploymentTest is Test, PENDeploymentHelper {
    bytes32 internal constant DEPLOYMENT_SALT = keccak256("pen-scripted-deployment-test");
    uint32 internal constant PROPOSAL_ID = 0;
    uint32 internal constant VOTING_PERIOD = 3 days;
    uint32 internal constant TIMELOCK_PERIOD = 1 days;
    uint32 internal constant EXECUTION_PERIOD = 2 days;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    ERC20Mock internal asset;
    ERC4626Mock internal principalVault;
    ERC4626Mock internal yieldVault;

    function setUp() public {
        asset = new ERC20Mock();
        principalVault = new ERC4626Mock(address(asset));
        yieldVault = new ERC4626Mock(address(asset));
    }

    function test_DeploySystemHandsOffAccessToSafe() public {
        DeploymentConfig memory config = _config();
        DeploymentAddresses memory preview =
            previewDeployment(address(this), vm.getNonce(address(this)), DEPLOYMENT_SALT, config);
        DeploymentAddresses memory deployed = _deploySystem(preview, DEPLOYMENT_SALT, config, address(this));

        assertEq(deployed.safe, preview.safe);
        assertTrue(Safe(payable(deployed.safe)).isModuleEnabled(deployed.azorius));

        SeatToken seatToken = SeatToken(deployed.seatToken);
        PrincipalManager principalManager = PrincipalManager(deployed.principalManager);
        BondingTranche bondingTranche = BondingTranche(deployed.bondingTranche);
        assertTrue(seatToken.hasRole(seatToken.DEFAULT_ADMIN_ROLE(), deployed.safe));
        assertFalse(seatToken.hasRole(seatToken.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(seatToken.hasRole(seatToken.ACTIVITY_ROLE(), deployed.strategy));
        assertTrue(seatToken.hasRole(seatToken.MINTER_ROLE(), deployed.bondingTranche));
        assertTrue(seatToken.hasRole(seatToken.BURNER_ROLE(), deployed.bondingTranche));

        assertTrue(principalManager.hasRole(principalManager.DEFAULT_ADMIN_ROLE(), deployed.safe));
        assertFalse(principalManager.hasRole(principalManager.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(principalManager.hasRole(principalManager.BONDING_ROLE(), deployed.bondingTranche));
        assertEq(address(principalManager.principalVault()), address(principalVault));
        assertEq(address(principalManager.yieldVault()), address(yieldVault));
        assertEq(principalManager.yieldVaultReceiver(), deployed.principalManager);
        assertEq(address(principalManager.fundingSlateExecutor()), deployed.fundingSlateExecutor);

        assertTrue(bondingTranche.hasRole(bondingTranche.DEFAULT_ADMIN_ROLE(), deployed.safe));
        assertFalse(bondingTranche.hasRole(bondingTranche.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(bondingTranche.hasRole(bondingTranche.RECLAIMER_ROLE(), deployed.safe));
        assertFalse(bondingTranche.hasRole(bondingTranche.RECLAIMER_ROLE(), address(this)));
    }

    function test_DeployedGovernanceCanExecuteAgainstPrincipalManager() public {
        DeploymentConfig memory config = _config();
        DeploymentAddresses memory deployed = _deploySystem(
            previewDeployment(address(this), vm.getNonce(address(this)), DEPLOYMENT_SALT, config),
            DEPLOYMENT_SALT,
            config,
            address(this)
        );

        BondingTranche bondingTranche = BondingTranche(deployed.bondingTranche);
        PrincipalManager principalManager = PrincipalManager(deployed.principalManager);
        PENRankedChoiceStrategy strategy = PENRankedChoiceStrategy(deployed.strategy);
        ModuleAzoriusV1 azorius = ModuleAzoriusV1(deployed.azorius);

        _buySeats(alice, bondingTranche, 4);
        _buySeats(bob, bondingTranche, 3);
        _buySeats(carol, bondingTranche, 2);

        Transaction[] memory transactions = new Transaction[](1);
        transactions[0] = Transaction({
            to: deployed.principalManager,
            value: 0,
            data: abi.encodeCall(PrincipalManager.setLiquidReserveTarget, (5 ether)),
            operation: Enum.Operation.Call
        });

        vm.prank(alice);
        azorius.submitProposal(transactions, "ipfs://pen-scripted/liquid-reserve-update", deployed.proposerAdapter, "");

        vm.prank(alice);
        strategy.submitSlate(PROPOSAL_ID, 1);
        vm.prank(bob);
        strategy.submitSlate(PROPOSAL_ID, 2);

        vm.warp(block.timestamp + 1);

        _castVote(strategy, alice, _ranking(1, 2, 0));
        _castVote(strategy, bob, _ranking(2, 1, 0));
        _castVote(strategy, carol, _ranking(2, 1, 0));

        (uint16 winningSlate, bool resolved) = strategy.getWinningSlate(PROPOSAL_ID);
        assertTrue(resolved);
        assertEq(winningSlate, 2);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.TIMELOCKED));

        vm.warp(block.timestamp + TIMELOCK_PERIOD + 1);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.EXECUTABLE));

        azorius.executeProposal(PROPOSAL_ID, transactions);

        assertEq(principalManager.liquidReserveTarget(), 5 ether);
        assertEq(uint8(azorius.proposalState(PROPOSAL_ID)), uint8(IModuleAzoriusV1.ProposalState.EXECUTED));
    }

    function _config() internal view returns (DeploymentConfig memory config) {
        config.core = CoreConfig({
            seatName: "PEN Seat",
            seatSymbol: "SEAT",
            seatSupplyCap: 10,
            inactivityPeriod: 365 days,
            refundPrice: 0.25 ether,
            liquidReserveTarget: 0,
            paymentAsset: address(asset),
            principalVault: address(principalVault),
            yieldVault: address(yieldVault),
            trancheUpperBounds: _singleUintArray(10),
            tranchePrices: _singleUintArray(1 ether)
        });

        config.governance = GovernanceConfig({
            votingPeriod: VOTING_PERIOD,
            timelockPeriod: TIMELOCK_PERIOD,
            executionPeriod: EXECUTION_PERIOD,
            quorumThreshold: 5,
            basisNumerator: 500_001,
            proposerThreshold: 1,
            votingWeightPerToken: 1,
            lightAccountFactory: address(0)
        });
    }

    function _buySeats(address buyer_, BondingTranche bondingTranche_, uint256 seats_) internal {
        uint256 cost = bondingTranche_.quotePurchase(seats_);
        asset.mint(buyer_, cost);
        vm.startPrank(buyer_);
        asset.approve(address(bondingTranche_), cost);
        bondingTranche_.purchase(buyer_, seats_, cost);
        vm.stopPrank();
    }

    function _castVote(
        PENRankedChoiceStrategy strategy_,
        address voter_,
        uint16[] memory ranking_
    ) internal {
        vm.prank(voter_);
        strategy_.castVote(PROPOSAL_ID, 1, _voteData(ranking_), 0);
    }

    function _voteData(
        uint16[] memory ranking_
    ) internal pure returns (IVotingTypes.VotingConfigVoteData[] memory votingConfigsData_) {
        votingConfigsData_ = new IVotingTypes.VotingConfigVoteData[](1);
        votingConfigsData_[0] = IVotingTypes.VotingConfigVoteData({configIndex: 0, voteData: abi.encode(ranking_)});
    }

    function _ranking(
        uint16 first_,
        uint16 second_,
        uint16 third_
    ) internal pure returns (uint16[] memory ranking_) {
        ranking_ = new uint16[](3);
        ranking_[0] = first_;
        ranking_[1] = second_;
        ranking_[2] = third_;
    }

    function _singleUintArray(uint256 value_) internal pure returns (uint256[] memory values_) {
        values_ = new uint256[](1);
        values_[0] = value_;
    }
}
