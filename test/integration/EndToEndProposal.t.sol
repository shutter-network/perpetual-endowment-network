// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import {SafeProxyFactory} from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";

import {ISpaceManager, IOwnable} from "../../script/PENDeploymentScriptBase.s.sol";
import {PENBootstrapHelper} from "../../script/BootstrapPEN.s.sol";
import {SeatToken} from "../../src/SeatToken.sol";
import {BondingTranche} from "../../src/BondingTranche.sol";
import {PrincipalManager} from "../../src/PrincipalManager.sol";
import {EthTxAuthenticator} from "@snapshot-x/authenticators/EthTxAuthenticator.sol";
import {OZVotesVotingStrategy} from "@snapshot-x/voting-strategies/OZVotesVotingStrategy.sol";

import {Choice, IndexedStrategy, Strategy, MetaTransaction, InitializeCalldata} from "@snapshot-x/types.sol";
import {SpaceInit} from "../helpers/SpaceInit.sol";
import {ProxyFactory} from "@snapshot-x/ProxyFactory.sol";
import {Space} from "@snapshot-x/Space.sol";
import {AvatarExecutionStrategy} from "@snapshot-x/execution-strategies/AvatarExecutionStrategy.sol";
import {TimelockExecutionStrategy} from "@snapshot-x/execution-strategies/timelocks/TimelockExecutionStrategy.sol";

import {StubProposalValidation} from "../helpers/StubProposalValidation.sol";

// Minimal local interface for Space actions used in tests to avoid bare-import type conflicts.
// TODO(upstream-fix): remove and import ISpaceActions/ISpaceState directly once
//   snapshot-labs/sx-evm replaces bare "src/types.sol" imports with relative paths.
interface ISpaceExec {
    function execute(uint256 proposalId, bytes calldata executionPayload) external;
    function nextProposalId() external view returns (uint256);
    function owner() external view returns (address);
}

contract EndToEndProposalTest is Test, PENBootstrapHelper {
    // ── Governance parameters ──────────────────────────────────────────────────

    uint32 internal constant QUORUM = 3;
    uint32 internal constant VOTING_DELAY = 1; // allows updateProposal before startBlockNumber
    uint32 internal constant MIN_VOTING_DURATION = 1;
    uint32 internal constant MAX_VOTING_DURATION = 100;
    uint32 internal constant PROPOSER_THRESHOLD = 1;

    // ── Authenticator selectors ────────────────────────────────────────────────

    bytes4 internal constant PROPOSE_SELECTOR = bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));
    bytes4 internal constant VOTE_SELECTOR = bytes4(keccak256("vote(address,uint256,uint8,(uint8,bytes)[],string)"));
    bytes4 internal constant UPDATE_PROPOSAL_SELECTOR =
        bytes4(keccak256("updateProposal(address,uint256,(address,bytes),string)"));

    // ── State ──────────────────────────────────────────────────────────────────

    DeploymentAddresses internal sys;
    address internal space; // Phase 2 output — the Space address, set after _bootstrapPEN.
    address internal execStrategy; // Phase 2 output — the UI-deployed exec strategy (Avatar or Timelock).
    MockUSDC internal paymentToken;
    address internal ozVotesStrategy;
    address internal ethTxAuthenticator;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal dan = makeAddr("dan");
    address internal eve = makeAddr("eve");
    address internal frank = makeAddr("frank"); // zero-seat actor
    address internal grantee = makeAddr("grantee");

    // ── setUp ─────────────────────────────────────────────────────────────────

    function setUp() public virtual {
        // Maintain invariant: block.timestamp = block.number + 1 throughout all tests.
        // This ensures getPastVotes(voter, blockNumber) does not hit ERC5805FutureLookup,
        // because the SeatToken clock() = block.timestamp = blockNumber + 1 > blockNumber.
        vm.roll(1);
        vm.warp(2);

        sys = _deployTestSystem(false, 0);

        vm.deal(sys.safe, 1 ether);

        // MINTER_ROLE for this test contract was granted during _deploySpaceAndFinalize,
        // before DEFAULT_ADMIN_ROLE on SeatToken was renounced. See that helper for context.
        SeatToken st = SeatToken(sys.seatToken);

        // alice=2, bob=1, charlie=1, dan=1, eve=1 → total 6 seats
        st.mint(alice, 2);
        st.mint(bob, 1);
        st.mint(charlie, 1);
        st.mint(dan, 1);
        st.mint(eve, 1);

        // Advance 1 block so getPastVotes is queryable at block.number snapshots.
        _advance(1);
    }

    // ── Helpers: advance ──────────────────────────────────────────────────────

    // Maintains block.timestamp = block.number + 1 invariant.
    function _advance(uint256 n) internal {
        vm.roll(block.number + n);
        vm.warp(block.timestamp + n);
    }

    // ── Helpers: payload builders ─────────────────────────────────────────────

    function _ethTransferPayload(address to, uint256 value) internal pure returns (bytes memory) {
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({to: to, value: value, data: "", operation: Enum.Operation.Call, salt: 0});
        return abi.encode(txs);
    }

    function _callPayload(address to, bytes memory data, uint256 salt) internal pure returns (bytes memory) {
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({to: to, value: 0, data: data, operation: Enum.Operation.Call, salt: salt});
        return abi.encode(txs);
    }

    // ── Helpers: Space interaction ────────────────────────────────────────────

    // The UI-deployed exec strategy: either `AvatarExecutionStrategy` (base test) or
    // `TimelockExecutionStrategy` (TimelockedExecutionTest). Set by `_deploySpaceAndFinalize`.
    function _activeExecStrategy() internal view returns (address) {
        return execStrategy;
    }

    function _defaultUserStrategies() internal pure returns (IndexedStrategy[] memory strats) {
        strats = new IndexedStrategy[](1);
        strats[0] = IndexedStrategy({index: 0, params: ""});
    }

    function _propose(address proposer, bytes memory payload) internal returns (uint256 proposalId) {
        proposalId = ISpaceExec(space).nextProposalId();

        bytes memory data = abi.encode(
            proposer, "", Strategy({addr: _activeExecStrategy(), params: payload}), abi.encode(_defaultUserStrategies())
        );

        vm.prank(proposer);
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, PROPOSE_SELECTOR, data);
    }

    function _vote(address voter, uint256 proposalId, Choice choice) internal {
        bytes memory data = abi.encode(voter, proposalId, choice, _defaultUserStrategies(), "");
        vm.prank(voter);
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, VOTE_SELECTOR, data);
    }

    function _executeProposal(uint256 proposalId, bytes memory payload) internal virtual {
        ISpaceExec(space).execute(proposalId, payload);
    }

    // ── Deploy helper ─────────────────────────────────────────────────────────

    // Deploys the full PEN system without using previewDeployment + nonce assertions.
    // previewDeployment counts deployer nonce increments assuming broadcast (one tx per call).
    // In a Foundry test, CALLs do not increment the deployer's nonce — only CREATE ops do.
    // This helper mirrors the production Phase 1 + Phase 2 flow: Phase 1 deploys the Safe
    // (owner = test contract, threshold = 1, no module) + core; Phase 2 deploys Space + exec
    // strategy via ProxyFactory (the in-test stand-in for snapshot.box) and then routes
    // through `_bootstrapPEN` (setSpace + enableModule + swapOwner).
    function _deployTestSystem(bool timelockEnabled, uint32 timelockDelay)
        internal
        returns (DeploymentAddresses memory d)
    {
        (address pf, address si, address pv) = _deployInfra(d);
        _deploySpaceAndFinalize(timelockEnabled, timelockDelay, d, pf, si, pv);
    }

    // Deploys all contracts except the Space + exec strategy; modifies d in place (memory ref).
    // Returns the three addresses needed by _deploySpaceAndFinalize.
    function _deployInfra(DeploymentAddresses memory d) private returns (address pf, address si, address pv) {
        ProxyFactory proxyFactory = new ProxyFactory();
        Space spaceImpl = new Space();
        // StubProposalValidation avoids PropositionPowerProposalValidationStrategy which
        // pulls PropositionPower → SXUtils → bare "src/types.sol" causing source-unit
        // ID conflicts (see StubProposalValidation.sol for details).
        StubProposalValidation propValidation = new StubProposalValidation();
        paymentToken = new MockUSDC();

        d.safeSingleton = address(new Safe());
        d.safeProxyFactory = address(new SafeProxyFactory());
        // Stock voting strategy — same one the production deploy script wires through
        // `SX_OZ_VOTES_STRATEGY`. Reads voting power from SeatToken.getPastVotes.
        ozVotesStrategy = address(new OZVotesVotingStrategy());
        // Stock EthTxAuthenticator is the sole whitelisted authenticator on the Space at launch.
        // Activity refresh is performed onchain via `SeatToken.refreshActivity` — no PEN-specific
        // authenticator is deployed.
        ethTxAuthenticator = address(new EthTxAuthenticator());

        // Phase 1 Safe: owner = test contract (stand-in for the deployer EOA), threshold = 1,
        // no module. Phase 2 enables the exec strategy as a module and swaps the sole owner.
        d.safe = _predictSafeAddress(d, address(this), bytes32(0));
        d.safe = address(
            SafeProxyFactory(d.safeProxyFactory)
                .createProxyWithNonce(d.safeSingleton, _safeInitializer(address(this)), uint256(0))
        );

        d.seatToken = address(
            new SeatToken(
                "PEN Seat",
                "SEAT",
                1_000_000,
                uint48(365 days),
                address(this),
                address(0),
                address(0),
                address(this), // bootstrap — the test contract calls setSpace after Space deploy
                d.safe // expectedOwner — Space's owner() must match this at setSpace time
            )
        );
        d.principalManager = address(
            new PrincipalManager(IERC20(address(paymentToken)), address(this), address(0), 0, IERC4626(address(0)))
        );

        {
            uint256[] memory bounds = new uint256[](1);
            bounds[0] = 1_000_000;
            uint256[] memory prices = new uint256[](1);
            prices[0] = 1; // strictly positive per BondingTranche validation
            d.bondingTranche = address(
                new BondingTranche(
                    SeatToken(d.seatToken),
                    PrincipalManager(d.principalManager),
                    0,
                    address(this),
                    address(this),
                    bounds,
                    prices
                )
            );
        }

        pf = address(proxyFactory);
        si = address(spaceImpl);
        pv = address(propValidation);
    }

    // Two-phase test harness that mirrors the production operator flow:
    //   Phase 1 → grant/finalize roles on SeatToken/PM/BT (matches `_finalizeAccess`).
    //   Phase 2 → deploy Space via ProxyFactory (the in-test stand-in for snapshot.box),
    //             deploy an exec strategy (Avatar or Timelock) with `spaces=[space]` and
    //             `controller=safe`, then call `_bootstrapPEN` to setSpace + enableModule
    //             + swapOwner. No shortcuts.
    function _deploySpaceAndFinalize(
        bool timelockEnabled,
        uint32 timelockDelay,
        DeploymentAddresses memory d,
        address pf,
        address si,
        address pv
    ) private {
        // ── Phase 1 role finalize (mirrors PENDeploymentHelper._finalizeAccess) ──
        {
            SeatToken st = SeatToken(d.seatToken);
            st.grantRole(st.MINTER_ROLE(), d.bondingTranche);
            // Test-only: also grant MINTER_ROLE to this test contract so per-test setUps can
            // mint seats directly without routing through BondingTranche.purchase. Must happen
            // before DEFAULT_ADMIN_ROLE is renounced.
            st.grantRole(st.MINTER_ROLE(), address(this));
            st.grantRole(st.BURNER_ROLE(), d.bondingTranche);
            // SeatToken.DEFAULT_ADMIN_ROLE intentionally left unheld — see _finalizeAccess.
            st.renounceRole(st.DEFAULT_ADMIN_ROLE(), address(this));
        }
        {
            PrincipalManager pm = PrincipalManager(d.principalManager);
            pm.grantRole(pm.BONDING_ROLE(), d.bondingTranche);
            pm.grantRole(pm.DEFAULT_ADMIN_ROLE(), d.safe);
            pm.renounceRole(pm.DEFAULT_ADMIN_ROLE(), address(this));
        }
        {
            BondingTranche bt = BondingTranche(d.bondingTranche);
            bt.grantRole(bt.RECLAIMER_ROLE(), d.safe);
            bt.grantRole(bt.DEFAULT_ADMIN_ROLE(), d.safe);
            bt.revokeRole(bt.RECLAIMER_ROLE(), address(this));
            bt.renounceRole(bt.DEFAULT_ADMIN_ROLE(), address(this));
        }

        // ── Phase 2 simulacrum: deploy the Space via ProxyFactory ─────────────
        // In production this is what `snapshot.box` does when the operator submits the form.
        // We use the shared `SpaceInit` builder — the same one Preview / BootstrapPEN
        // reference — so tests and production stay aligned on the initialize calldata shape.
        address spaceAddr;
        {
            SpaceInit.Params memory params = SpaceInit.Params({
                owner: d.safe,
                seatToken: d.seatToken,
                ozVotesStrategy: ozVotesStrategy,
                // StubProposalValidation decodes params as (uint256 threshold, address seatToken).
                // Production uses PropositionPowerProposalValidationStrategy with (uint256, Strategy[]).
                proposalValidationStrategy: Strategy({
                    addr: pv, params: abi.encode(uint256(PROPOSER_THRESHOLD), d.seatToken)
                }),
                ethTxAuthenticator: ethTxAuthenticator,
                votingDelay: VOTING_DELAY,
                minVotingDuration: MIN_VOTING_DURATION,
                maxVotingDuration: MAX_VOTING_DURATION,
                metadataURI: "",
                daoURI: "",
                proposalValidationStrategyMetadataURI: "",
                votingStrategyMetadataURI: ""
            });
            InitializeCalldata memory init = SpaceInit.buildInitializeCalldata(params);
            ProxyFactory(pf).deployProxy(si, SpaceInit.encodeInitializeCall(init), 0);
            spaceAddr = _computeProxyAddress(pf, si, address(this), 0);
        }

        // ── Phase 2 simulacrum: deploy the exec strategy pointed at the Space ─
        // The sx-monorepo wizard batches this with the Space create tx. We do it here in
        // one deploy: controller = Safe (so no post-hoc transferOwnership needed), spaces =
        // [space] (so no post-hoc enableSpace needed).
        execStrategy = _deployExecStrategyForSpace(pf, spaceAddr, d.safe, timelockEnabled, timelockDelay);

        // ── Phase 2 finalize: setSpace + Safe.enableModule + Safe.swapOwner ───
        _bootstrapPEN(d, spaceAddr, execStrategy, address(this));
        space = spaceAddr;
    }

    // Deploys an AvatarExecutionStrategy (base test) or TimelockExecutionStrategy
    // (TimelockedExecutionTest) via ProxyFactory, matching the wizard's Executions step.
    function _deployExecStrategyForSpace(
        address proxyFactory,
        address spaceAddr,
        address safe,
        bool timelockEnabled,
        uint32 timelockDelay
    ) private returns (address deployed) {
        address[] memory spaces = new address[](1);
        spaces[0] = spaceAddr;
        if (timelockEnabled) {
            TimelockExecutionStrategy impl = new TimelockExecutionStrategy();
            ProxyFactory(proxyFactory)
                .deployProxy(
                    address(impl),
                    abi.encodeCall(
                        TimelockExecutionStrategy.setUp,
                        (abi.encode(safe, address(0), spaces, uint256(timelockDelay), uint256(QUORUM)))
                    ),
                    1
                );
            deployed = _computeProxyAddress(proxyFactory, address(impl), address(this), 1);
        } else {
            AvatarExecutionStrategy impl =
                new AvatarExecutionStrategy(address(this), address(this), new address[](0), 1);
            ProxyFactory(proxyFactory)
                .deployProxy(
                    address(impl),
                    abi.encodeCall(AvatarExecutionStrategy.setUp, (abi.encode(safe, safe, spaces, uint256(QUORUM)))),
                    1
                );
            deployed = _computeProxyAddress(proxyFactory, address(impl), address(this), 1);
        }
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    // All 5 holders vote For; quorum met (6 >= 3); simple majority (6 > 0);
    // grantee receives 1 ETH; alice + each voter's lastActivityAt updated.
    function test_happyPath_proposeVoteExecute() public {
        bytes memory payload = _ethTransferPayload(grantee, 1 ether);

        uint256 balanceBefore = grantee.balance;
        uint256 proposalId = _propose(alice, payload);
        uint48 aliceActivityAfterPropose = SeatToken(sys.seatToken).lastActivityAt(alice);

        // Advance 2 blocks: startBlockNumber = proposeBlock+1, minEnd = proposeBlock+2.
        // At minEnd, VotingPeriodAccepted is reachable (early execution allowed).
        _advance(2);

        _vote(alice, proposalId, Choice.For);
        _vote(bob, proposalId, Choice.For);
        _vote(charlie, proposalId, Choice.For);
        _vote(dan, proposalId, Choice.For);
        _vote(eve, proposalId, Choice.For);

        uint48 bobActivityAfterVote = SeatToken(sys.seatToken).lastActivityAt(bob);

        _executeProposal(proposalId, payload);

        assertEq(grantee.balance - balanceBefore, 1 ether);
        assertGt(aliceActivityAfterPropose, 0);
        assertGt(bobActivityAfterVote, 0);
    }

    // 4 For vs 2 Against, quorum=3 met → executes.
    // Snapshot X uses simple majority (votesFor > votesAgainst).
    // Under the prior 70% supermajority rule (Decent/Azorius), 4/6 ≈ 67% would have failed.
    function test_simpleMajority_passes() public {
        bytes memory payload = _ethTransferPayload(grantee, 0.1 ether);
        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For); // +2
        _vote(bob, proposalId, Choice.For); // +1  → 3 For
        _vote(charlie, proposalId, Choice.For); // +1  → 4 For
        _vote(dan, proposalId, Choice.Against); // +1  → 1 Against
        _vote(eve, proposalId, Choice.Against); // +1  → 2 Against

        // votesFor=4 > votesAgainst=2; quorum 4+0=4 >= 3 → VotingPeriodAccepted
        _executeProposal(proposalId, payload);
        assertEq(grantee.balance, 0.1 ether);
    }

    // 3 For vs 3 Against → _supported == false → execute reverts.
    function test_tie_fails() public virtual {
        bytes memory payload = _ethTransferPayload(grantee, 0.1 ether);
        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For); // +2 → 2 For
        _vote(bob, proposalId, Choice.For); // +1 → 3 For
        _vote(charlie, proposalId, Choice.Against); // +1 → 1 Against
        _vote(dan, proposalId, Choice.Against); // +1 → 2 Against
        _vote(eve, proposalId, Choice.Against); // +1 → 3 Against

        // Advance past maxVotingDuration to force Rejected status (not VotingPeriodAccepted)
        _advance(MAX_VOTING_DURATION);

        // InvalidProposalStatus(Rejected=5) — enum uint8 value 5
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("InvalidProposalStatus(uint8)")), uint8(5)));
        _executeProposal(proposalId, payload);
    }

    // Only alice (2 seats) votes For; 2 < QUORUM (3) → proposal is Rejected.
    function test_quorumFails_proposalNotExecutable() public virtual {
        bytes memory payload = _ethTransferPayload(grantee, 0.1 ether);
        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For); // 2 seats; quorum threshold = 3

        _advance(MAX_VOTING_DURATION);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("InvalidProposalStatus(uint8)")), uint8(5)));
        _executeProposal(proposalId, payload);
    }

    // Actor with 0 seats (frank) tries to propose; fails PropositionPower validation.
    function test_propose_belowProposerThreshold_reverts() public {
        bytes memory payload = _ethTransferPayload(grantee, 0);

        IndexedStrategy[] memory userStrats = _defaultUserStrategies();
        bytes memory data =
            abi.encode(frank, "", Strategy({addr: _activeExecStrategy(), params: payload}), abi.encode(userStrats));

        vm.prank(frank);
        vm.expectRevert(bytes4(keccak256("FailedToPassProposalValidation()")));
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, PROPOSE_SELECTOR, data);
    }

    // Actor with 0 seats (frank) votes; Space reverts with UserHasNoVotingPower,
    // propagated through the authenticator. lastActivityAt is never updated.
    function test_vote_zeroPower_doesNotRevertAuthenticator_doesNotRecordActivity() public {
        bytes memory payload = _ethTransferPayload(grantee, 0);
        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        bytes memory voteData = abi.encode(frank, proposalId, Choice.For, _defaultUserStrategies(), "");

        vm.prank(frank);
        vm.expectRevert(bytes4(keccak256("UserHasNoVotingPower()")));
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, VOTE_SELECTOR, voteData);

        assertEq(SeatToken(sys.seatToken).lastActivityAt(frank), 0);
    }

    // Proposal snapshot taken at T; new member mints seats at T+1; their power at the
    // proposal is 0 because getPastVotes uses the snapshot timestamp.
    function test_pastSnapshot_unaffectedByLaterMint() public {
        address lateMember = makeAddr("lateMember");

        bytes memory payload = _ethTransferPayload(grantee, 0);
        // Propose at block B; startBlockNumber = B+1 (snapshot timestamp)
        uint256 proposalId = _propose(alice, payload);

        // Mint lateMember at the SAME block as propose. The snapshot is B+1 (future block),
        // so getPastVotes(lateMember, B+1) will look BEFORE the mint checkpoint at T=B+2.
        // Actually mint here at T = block.timestamp at propose time.
        // After _advance(2): block = B+2, lateMember minted at B+2 → checkpoint at T=B+3.
        // Snapshot = B+1 < B+3 → getPastVotes returns 0. ✓
        _advance(2);
        SeatToken(sys.seatToken).mint(lateMember, 10); // checkpoint at T = block.timestamp = B+3

        bytes memory voteData = abi.encode(lateMember, proposalId, Choice.For, _defaultUserStrategies(), "");

        vm.prank(lateMember);
        vm.expectRevert(bytes4(keccak256("UserHasNoVotingPower()")));
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, VOTE_SELECTOR, voteData);
    }

    // Several voters cast votes through the real sx-evm Space; a single keeper-style call
    // to `refreshActivityForProposalVoters` refreshes all of them in one tx.
    function test_batchRefresh_forProposalVoters_throughRealSpace() public {
        bytes memory payload = _ethTransferPayload(grantee, 0);
        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For);
        _vote(bob, proposalId, Choice.For);
        _vote(charlie, proposalId, Choice.For);

        SeatToken st = SeatToken(sys.seatToken);
        uint48 aliceBefore = st.lastActivityAt(alice);
        uint48 bobBefore = st.lastActivityAt(bob);
        uint48 charlieBefore = st.lastActivityAt(charlie);

        _advance(1); // advance so refresh timestamp is strictly greater than the mint anchor

        address[] memory voters = new address[](4);
        voters[0] = alice;
        voters[1] = bob;
        voters[2] = charlie;
        voters[3] = frank; // zero-seat: must be silently skipped, not revert
        st.refreshActivityForProposalVoters(proposalId, voters);

        assertGt(st.lastActivityAt(alice), aliceBefore);
        assertGt(st.lastActivityAt(bob), bobBefore);
        assertGt(st.lastActivityAt(charlie), charlieBefore);
        assertEq(st.lastActivityAt(frank), 0);
    }

    // Two voters vote on two different proposals via the real sx-evm Space; a single
    // `refreshActivityBatch` call refreshes both across the parallel arrays.
    function test_batchRefresh_mixedProposals_throughRealSpace() public {
        bytes memory payload1 = _ethTransferPayload(grantee, 0);
        bytes memory payload2 = _ethTransferPayload(grantee, 0);
        uint256 id1 = _propose(alice, payload1);
        _advance(2);
        _vote(alice, id1, Choice.For);

        uint256 id2 = _propose(bob, payload2);
        _advance(2);
        _vote(bob, id2, Choice.For);

        SeatToken st = SeatToken(sys.seatToken);
        uint48 aliceBefore = st.lastActivityAt(alice);
        uint48 bobBefore = st.lastActivityAt(bob);

        _advance(1);

        address[] memory voters = new address[](2);
        voters[0] = alice;
        voters[1] = bob;
        uint256[] memory proposalIds = new uint256[](2);
        proposalIds[0] = id1;
        proposalIds[1] = id2;
        st.refreshActivityBatch(voters, proposalIds);

        assertGt(st.lastActivityAt(alice), aliceBefore);
        assertGt(st.lastActivityAt(bob), bobBefore);
    }

    // Alice votes Abstain, then triggers `SeatToken.refreshActivity`; abstain counts toward
    // quorum but does NOT count toward _supported. Verifies the split-tx (vote, then refresh)
    // flow used under the redesigned activity model.
    function test_activityRecorded_onAbstain() public {
        bytes memory payload = _ethTransferPayload(grantee, 0.1 ether);
        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        uint48 activityBefore = SeatToken(sys.seatToken).lastActivityAt(alice);

        _vote(alice, proposalId, Choice.Abstain);
        SeatToken(sys.seatToken).refreshActivity(alice, proposalId);

        uint48 activityAfter = SeatToken(sys.seatToken).lastActivityAt(alice);
        assertGt(activityAfter, activityBefore);

        _vote(bob, proposalId, Choice.For);
        _vote(charlie, proposalId, Choice.For);

        _executeProposal(proposalId, payload);
        assertEq(grantee.balance, 0.1 ether);
    }

    // Alice updates her own proposal (before voting starts) via the stock EthTxAuthenticator.
    // A follow-up `SeatToken.refreshActivityForProposal(alice, id)` credits her — the same
    // address gets one refresh anchor at `startBlockNumber`. `updateProposal` gains no extra
    // credit because only the original author can ever update (Design Decision #7).
    function test_activityRecorded_onUpdateProposal() public {
        bytes memory originalPayload = _ethTransferPayload(grantee, 0);
        bytes memory updatedPayload = _ethTransferPayload(grantee, 0.1 ether);

        uint256 proposalId = _propose(alice, originalPayload);
        uint48 activityBeforeUpdate = SeatToken(sys.seatToken).lastActivityAt(alice);

        bytes memory updateData =
            abi.encode(alice, proposalId, Strategy({addr: _activeExecStrategy(), params: updatedPayload}), "");

        vm.prank(alice);
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, UPDATE_PROPOSAL_SELECTOR, updateData);

        SeatToken(sys.seatToken).refreshActivityForProposal(alice, proposalId);

        uint48 activityAfterUpdate = SeatToken(sys.seatToken).lastActivityAt(alice);
        assertGe(activityAfterUpdate, activityBeforeUpdate);

        _advance(2);
        _vote(alice, proposalId, Choice.For);
        _vote(bob, proposalId, Choice.For);
        _vote(charlie, proposalId, Choice.For);
        _executeProposal(proposalId, updatedPayload);
        assertEq(grantee.balance, 0.1 ether);
    }

    // Warp 365+ days with no activity for bob; alice proposes reclaim;
    // vote passes; bob's seat is burned.
    function test_reclaim_throughGovernance() public {
        // Warp so bob (lastActivityAt = 2 from setUp mint) is inactive.
        // Advance enough that 2 + 365 days <= block.timestamp.
        _advance(uint48(365 days) + 1);

        assertTrue(SeatToken(sys.seatToken).isInactive(bob));

        bytes memory reclaimData = abi.encodeCall(BondingTranche.reclaim, (bob));
        bytes memory payload = _callPayload(sys.bondingTranche, reclaimData, 0);

        uint256 supplyBefore = SeatToken(sys.seatToken).totalSupply();

        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For); // 2
        _vote(charlie, proposalId, Choice.For); // 1 → 3 total ≥ quorum
        _vote(dan, proposalId, Choice.For);

        _executeProposal(proposalId, payload);

        assertEq(SeatToken(sys.seatToken).balanceOf(bob), 0);
        assertEq(SeatToken(sys.seatToken).totalSupply(), supplyBefore - 1);
    }

    // Bob votes on the reclaim proposal before execution, then a follow-up
    // `SeatToken.refreshActivity` marks him active. When Safe executes bondingTranche.reclaim(bob),
    // isInactive(bob) == false → reverts. Verifies: BondingTranche.reclaim evaluates isInactive
    // at call time, not snapshot time.
    function test_reclaim_evadedByOnTimeVote() public virtual {
        _advance(uint48(365 days) + 1);

        assertTrue(SeatToken(sys.seatToken).isInactive(bob));

        bytes memory reclaimData = abi.encodeCall(BondingTranche.reclaim, (bob));
        bytes memory payload = _callPayload(sys.bondingTranche, reclaimData, 0);

        uint256 proposalId = _propose(alice, payload);
        _advance(2);

        _vote(alice, proposalId, Choice.For); // 2
        _vote(charlie, proposalId, Choice.For); // 1 → 3 ≥ quorum
        _vote(dan, proposalId, Choice.For);

        _vote(bob, proposalId, Choice.Against);
        SeatToken(sys.seatToken).refreshActivity(bob, proposalId);

        assertFalse(SeatToken(sys.seatToken).isInactive(bob));

        // Execute: Safe tries reclaim(bob) but isInactive=false → HolderStillActive →
        // Safe.execTransactionFromModule returns false → AvatarExecutionStrategy reverts ExecutionFailed
        vm.expectRevert(bytes4(keccak256("ExecutionFailed()")));
        _executeProposal(proposalId, payload);

        // Bob's seat is NOT burned
        assertEq(SeatToken(sys.seatToken).balanceOf(bob), 1);
    }

    // After mass reclaim, the sole remaining active member can still pass proposals solo.
    // Verifies: quorum is evaluated against absolute vote count, not percentage of total supply.
    function test_massReclaimThenSoleMemberGovernanceContinues() public {
        address mActive = makeAddr("mActive");
        address mInactive = makeAddr("mInactive");

        SeatToken(sys.seatToken).mint(mActive, 100);
        SeatToken(sys.seatToken).mint(mInactive, 100);
        _advance(1);

        // mActive participates in a governance vote and refreshes to record recent activity.
        bytes memory dummyPayload = _ethTransferPayload(grantee, 0);
        uint256 warmupId = _propose(alice, dummyPayload);
        _advance(2);
        _vote(mActive, warmupId, Choice.For);
        SeatToken(sys.seatToken).refreshActivity(mActive, warmupId);
        _vote(alice, warmupId, Choice.For); // quorum: 100+2 >> 3
        _executeProposal(warmupId, dummyPayload);

        // Warp so mInactive (never voted, lastActivityAt = 3) is inactive but mActive is not.
        // mInactive: 3 + 365 days ≤ T_warp → inactive.
        // mActive: vote at T_vote, T_vote + 365 days > T_warp → active.
        // Choose warp such that 3+365d ≤ T_warp < T_vote+365d.
        // T_vote ≈ block.timestamp after warmup (≈ 7). 7+365d = 31536007.
        // Warp from current timestamp to 3+365d+1 = 31536004.
        uint256 inactivityTarget = 3 + uint256(365 days) + 1;
        uint256 warpAmount = inactivityTarget > block.timestamp ? inactivityTarget - block.timestamp : 0;
        _advance(warpAmount);

        assertTrue(SeatToken(sys.seatToken).isInactive(mInactive));
        assertFalse(SeatToken(sys.seatToken).isInactive(mActive));

        // Reclaim mInactive directly via Safe (RECLAIMER_ROLE)
        vm.prank(sys.safe);
        BondingTranche(sys.bondingTranche).reclaim(mInactive);
        assertEq(SeatToken(sys.seatToken).balanceOf(mInactive), 0);

        // mActive can still govern solo: 100 seats >> quorum 3
        bytes memory govPayload = _ethTransferPayload(grantee, 0.1 ether);
        uint256 govId = _propose(mActive, govPayload);
        _advance(2);
        _vote(mActive, govId, Choice.For);
        _executeProposal(govId, govPayload);
        assertEq(grantee.balance, 0.1 ether);
    }

    // After _deployTestSystem, the Safe holds all admin roles and the deployer has
    // renounced everything. This mirrors PENScriptedDeployment::test_DeploySystemHandsOffAccessToSafe.
    function test_deploySystem_handsOffAccessToSafe() public virtual {
        SeatToken st = SeatToken(sys.seatToken);
        PrincipalManager pm = PrincipalManager(sys.principalManager);
        BondingTranche bt = BondingTranche(sys.bondingTranche);

        // SeatToken — DEFAULT_ADMIN_ROLE intentionally unheld; roles are immutable post-deploy.
        assertFalse(st.hasRole(st.DEFAULT_ADMIN_ROLE(), sys.safe));
        assertFalse(st.hasRole(st.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(st.hasRole(st.MINTER_ROLE(), sys.bondingTranche));
        assertTrue(st.hasRole(st.MINTER_ROLE(), address(this))); // test-only minter; granted pre-renounce
        assertTrue(st.hasRole(st.BURNER_ROLE(), sys.bondingTranche));

        // PrincipalManager
        assertTrue(pm.hasRole(pm.DEFAULT_ADMIN_ROLE(), sys.safe));
        assertFalse(pm.hasRole(pm.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(pm.hasRole(pm.BONDING_ROLE(), sys.bondingTranche));

        // BondingTranche
        assertTrue(bt.hasRole(bt.DEFAULT_ADMIN_ROLE(), sys.safe));
        assertFalse(bt.hasRole(bt.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(bt.hasRole(bt.RECLAIMER_ROLE(), sys.safe));
        assertFalse(bt.hasRole(bt.RECLAIMER_ROLE(), address(this)));

        // Safe module + sole owner both point at the UI-deployed exec strategy
        assertTrue(Safe(payable(sys.safe)).isModuleEnabled(execStrategy));
        address[] memory safeOwners = Safe(payable(sys.safe)).getOwners();
        assertEq(safeOwners.length, 1);
        assertEq(safeOwners[0], execStrategy);

        // Execution strategy
        assertEq(ISpaceManager(execStrategy).isSpaceEnabled(space), 1);
        assertEq(IOwnable(execStrategy).owner(), sys.safe);

        // Space
        assertEq(ISpaceExec(space).owner(), sys.safe);
    }

    // The Safe holds DEFAULT_ADMIN_ROLE on PrincipalManager and BondingTranche (needed for
    // executeFunding, asset migration, extendTranches, etc.) but NOT on SeatToken — so even
    // a captured governance majority cannot reroute MINTER_ROLE or BURNER_ROLE to dilute or
    // confiscate seats.
    function test_seatTokenRoles_areFrozen_safeCannotReroute() public {
        SeatToken st = SeatToken(sys.seatToken);
        address attacker = makeAddr("attacker");
        // Resolve role IDs outside the prank — st.MINTER_ROLE() is an external call that
        // would otherwise consume a single-use vm.prank before grantRole is reached.
        bytes32 minterRole = st.MINTER_ROLE();
        bytes32 burnerRole = st.BURNER_ROLE();

        // The Safe (admin on every other contract) cannot grant MINTER on the seat token.
        vm.prank(sys.safe);
        vm.expectRevert();
        st.grantRole(minterRole, attacker);

        // …or BURNER.
        vm.prank(sys.safe);
        vm.expectRevert();
        st.grantRole(burnerRole, attacker);

        // …or revoke the existing grants to BondingTranche.
        vm.prank(sys.safe);
        vm.expectRevert();
        st.revokeRole(minterRole, sys.bondingTranche);

        vm.prank(sys.safe);
        vm.expectRevert();
        st.revokeRole(burnerRole, sys.bondingTranche);
    }
}
