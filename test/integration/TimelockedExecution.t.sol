// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";

import {SeatToken} from "../../src/SeatToken.sol";
import {BondingTranche} from "../../src/BondingTranche.sol";
import {PrincipalManager} from "../../src/PrincipalManager.sol";
import {TimelockExecutionStrategy} from "@snapshot-x/execution-strategies/timelocks/TimelockExecutionStrategy.sol";
import {Choice, MetaTransaction} from "@snapshot-x/types.sol";

import {ISpaceManager, IOwnable} from "../../script/PENDeploymentScriptBase.s.sol";
import {EndToEndProposalTest, ISpaceExec} from "./EndToEndProposal.t.sol";

// Inherits all 13 EndToEndProposalTest tests and runs them through a 1-day timelock.
// Key differences from the base setup:
//  - sys.timelockExecutionStrategy is used as the proposal execution strategy
//  - TimelockExecutionStrategy.executeQueuedProposal executes MetaTransactions directly
//    (not via Safe), so the TimelockExecutionStrategy itself is funded with ETH
//  - _executeProposal is overridden to: queue via Space.execute, advance past the delay,
//    then finalize via executeQueuedProposal
//  - test_reclaim_evadedByOnTimeVote and test_deploySystem_handsOffAccessToSafe are
//    overridden to account for the timelock routing differences
contract TimelockedExecutionTest is EndToEndProposalTest {
    uint32 internal constant TIMELOCK_DELAY_SECS = uint32(1 days);

    function setUp() public override {
        vm.roll(1);
        vm.warp(2);

        sys = _deployTestSystem(true, TIMELOCK_DELAY_SECS);

        // Fund the TimelockExecutionStrategy directly for ETH transfer tests.
        // Unlike AvatarExecutionStrategy (which routes calls through Safe), the timelock
        // executes MetaTransactions from its own context, so it must hold the ETH itself.
        vm.deal(sys.timelockExecutionStrategy, 1 ether);

        // MINTER_ROLE for this test contract was granted during _deploySpaceAndFinalize,
        // before DEFAULT_ADMIN_ROLE on SeatToken was renounced. See that helper for context.
        SeatToken st = SeatToken(sys.seatToken);

        st.mint(alice, 2);
        st.mint(bob, 1);
        st.mint(charlie, 1);
        st.mint(dan, 1);
        st.mint(eve, 1);

        _advance(1);
    }

    // ── Override: route execution through the timelock ─────────────────────────
    // Queue via Space.execute, advance past the delay, then finalize.
    // Tests that use vm.expectRevert on a rejected proposal (test_tie_fails,
    // test_quorumFails_proposalNotExecutable) are overridden separately because
    // vm.expectRevert would intercept the Space.execute call and allow execution
    // to continue to executeQueuedProposal on an empty queue.
    function _executeProposal(uint256 proposalId, bytes memory payload) internal override {
        ISpaceExec(sys.space).execute(proposalId, payload);
        _advance(TIMELOCK_DELAY_SECS + 1);
        TimelockExecutionStrategy(payable(sys.timelockExecutionStrategy)).executeQueuedProposal(payload);
    }

    // ── Override: rejected proposals never enter the timelock ─────────────────
    // vm.expectRevert must be placed directly before the Space.execute call.
    // If placed before _executeProposal, it would intercept Space.execute, swallow
    // the InvalidProposalStatus revert, and let execution continue to
    // executeQueuedProposal — which then fails with ProposalNotQueued().
    function test_tie_fails() public override {
        bytes memory payload = _ethTransferPayload(grantee, 0.1 ether);
        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For);
        _vote(bob, proposalId, Choice.For);
        _vote(charlie, proposalId, Choice.Against);
        _vote(dan, proposalId, Choice.Against);
        _vote(eve, proposalId, Choice.Against);

        _advance(MAX_VOTING_DURATION);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("InvalidProposalStatus(uint8)")), uint8(5)));
        ISpaceExec(sys.space).execute(proposalId, payload);
    }

    function test_quorumFails_proposalNotExecutable() public override {
        bytes memory payload = _ethTransferPayload(grantee, 0.1 ether);
        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For);

        _advance(MAX_VOTING_DURATION);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("InvalidProposalStatus(uint8)")), uint8(5)));
        ISpaceExec(sys.space).execute(proposalId, payload);
    }

    // ── Override: reclaim evasion via timely vote ──────────────────────────────
    // Cannot use the base test's vm.expectRevert pattern because the inherited
    // _executeProposal makes two external calls (Space.execute succeeds first,
    // which would trip a single-use expectRevert). Instead, verify the correct
    // revert from executeQueuedProposal directly.
    function test_reclaim_evadedByOnTimeVote() public override {
        _advance(uint48(365 days) + 1);
        assertTrue(SeatToken(sys.seatToken).isInactive(bob));

        bytes memory reclaimData = abi.encodeCall(BondingTranche.reclaim, (bob));
        bytes memory payload = _callPayload(sys.bondingTranche, reclaimData, 0);

        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For);
        _vote(charlie, proposalId, Choice.For);
        _vote(dan, proposalId, Choice.For);
        _vote(bob, proposalId, Choice.Against);

        assertFalse(SeatToken(sys.seatToken).isInactive(bob));

        // Queue the payload in the timelock
        ISpaceExec(sys.space).execute(proposalId, payload);

        // Advance past the delay
        _advance(TIMELOCK_DELAY_SECS + 1);

        // executeQueuedProposal calls BondingTranche.reclaim(bob) directly via low-level
        // call. Since isInactive(bob)==false, the call fails → ExecutionFailed() is thrown.
        vm.expectRevert(bytes4(keccak256("ExecutionFailed()")));
        TimelockExecutionStrategy(payable(sys.timelockExecutionStrategy)).executeQueuedProposal(payload);

        assertEq(SeatToken(sys.seatToken).balanceOf(bob), 1);
    }

    // ── Override: access-handoff assertions for timelock topology ─────────────
    // In the timelocked configuration the routing is:
    //   Space → TimelockExecutionStrategy → (queues) → executeQueuedProposal → direct calls
    // NOT through AvatarExecutionStrategy → Safe. So the space-manager assertions differ.
    function test_deploySystem_handsOffAccessToSafe() public view override {
        SeatToken st = SeatToken(sys.seatToken);
        PrincipalManager pm = PrincipalManager(sys.principalManager);
        BondingTranche bt = BondingTranche(sys.bondingTranche);

        // SeatToken — DEFAULT_ADMIN_ROLE intentionally unheld; roles are immutable post-deploy.
        assertFalse(st.hasRole(st.DEFAULT_ADMIN_ROLE(), sys.safe));
        assertFalse(st.hasRole(st.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(st.hasRole(st.MINTER_ROLE(), sys.bondingTranche));
        assertTrue(st.hasRole(st.MINTER_ROLE(), address(this))); // test-only minter; granted pre-renounce
        assertTrue(st.hasRole(st.BURNER_ROLE(), sys.bondingTranche));
        assertTrue(st.hasRole(st.ACTIVITY_ROLE(), sys.penTxAuthenticator));

        // PrincipalManager
        assertTrue(pm.hasRole(pm.DEFAULT_ADMIN_ROLE(), sys.safe));
        assertFalse(pm.hasRole(pm.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(pm.hasRole(pm.BONDING_ROLE(), sys.bondingTranche));

        // BondingTranche
        assertTrue(bt.hasRole(bt.DEFAULT_ADMIN_ROLE(), sys.safe));
        assertFalse(bt.hasRole(bt.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(bt.hasRole(bt.RECLAIMER_ROLE(), sys.safe));
        assertFalse(bt.hasRole(bt.RECLAIMER_ROLE(), address(this)));

        // In timelocked mode the Safe enables TimelockExecutionStrategy as its module
        // (not AvatarExecutionStrategy). See _safeInitializer: moduleToEnable = timelockExec.
        assertTrue(Safe(payable(sys.safe)).isModuleEnabled(sys.timelockExecutionStrategy));

        // AvatarExecutionStrategy has TimelockExecutionStrategy enabled as a "space"
        // (AvatarExec is in the deployment but not on the hot execution path when a
        // timelocked strategy is used — Space.execute goes directly to TimelockExec).
        assertEq(ISpaceManager(sys.executionStrategy).isSpaceEnabled(sys.timelockExecutionStrategy), 1);
        assertEq(IOwnable(sys.executionStrategy).owner(), sys.safe);

        // TimelockExecutionStrategy has Space enabled and is owned by Safe
        assertEq(ISpaceManager(sys.timelockExecutionStrategy).isSpaceEnabled(sys.space), 1);
        assertEq(IOwnable(sys.timelockExecutionStrategy).owner(), sys.safe);

        // Space
        assertEq(ISpaceExec(sys.space).owner(), sys.safe);
    }

    // ── Timelock-specific tests ────────────────────────────────────────────────

    // Pass a proposal, queue it in the timelock, warp past the delay, execute.
    function test_executeViaTimelock_succeedsAfterDelay() public {
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({to: grantee, value: 0.1 ether, data: "", operation: Enum.Operation.Call, salt: 0});
        bytes memory payload = abi.encode(txs);

        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For); // 2 seats
        _vote(bob, proposalId, Choice.For); // 1 → 3 ≥ quorum
        _vote(charlie, proposalId, Choice.For); // 1 → 4

        // Space.execute → TimelockExecutionStrategy.execute → queues the payload hash
        ISpaceExec(sys.space).execute(proposalId, payload);

        // Payload is queued but not yet executed; grantee balance unchanged
        assertEq(grantee.balance, 0);

        // Warp past the timelock delay
        _advance(TIMELOCK_DELAY_SECS + 1);

        // Execute the queued proposal
        TimelockExecutionStrategy(payable(sys.timelockExecutionStrategy)).executeQueuedProposal(payload);

        assertEq(grantee.balance, 0.1 ether);
    }

    // After Space.execute queues the payload, calling executeQueuedProposal before the
    // timelock delay elapses reverts with TimelockDelayNotMet.
    function test_executeViaTimelock_revertsBeforeDelay() public {
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({to: grantee, value: 0.1 ether, data: "", operation: Enum.Operation.Call, salt: 0});
        bytes memory payload = abi.encode(txs);

        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For);
        _vote(bob, proposalId, Choice.For);
        _vote(charlie, proposalId, Choice.For);

        ISpaceExec(sys.space).execute(proposalId, payload);

        // Attempt to execute before delay has elapsed
        vm.expectRevert(bytes4(keccak256("TimelockDelayNotMet()")));
        TimelockExecutionStrategy(payable(sys.timelockExecutionStrategy)).executeQueuedProposal(payload);

        assertEq(grantee.balance, 0);
    }
}
