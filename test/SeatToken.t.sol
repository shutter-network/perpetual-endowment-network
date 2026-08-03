// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {ERC20Votes} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Votes.sol";

import {SeatToken} from "../src/SeatToken.sol";

import {ProxyFactory} from "@snapshot-x/ProxyFactory.sol";
import {Space} from "@snapshot-x/Space.sol";
import {EthTxAuthenticator} from "@snapshot-x/authenticators/EthTxAuthenticator.sol";
import {OZVotesVotingStrategy} from "@snapshot-x/voting-strategies/OZVotesVotingStrategy.sol";
import {Choice, IndexedStrategy, Proposal, Strategy, MetaTransaction, InitializeCalldata} from "@snapshot-x/types.sol";

import {StubProposalValidation} from "./helpers/StubProposalValidation.sol";
import {SpaceInit} from "./helpers/SpaceInit.sol";

// Local view surface used to read proposal metadata / next-id from a real Space in tests.
// `proposals(uint256)` returns the Proposal struct as a memory struct here rather than the
// tuple that Space's public getter yields — matches how SeatToken.sol reads the same field.
interface ISpaceExec {
    function nextProposalId() external view returns (uint256);
    function owner() external view returns (address);
    function proposals(uint256 proposalId) external view returns (Proposal memory);
}

contract SeatTokenTest is Test {
    // ── Governance parameters used to shape every real Space deployed in these tests ─────
    uint32 internal constant VOTING_DELAY = 1;
    uint32 internal constant MIN_VOTING_DURATION = 1;
    uint32 internal constant MAX_VOTING_DURATION = 10;
    uint32 internal constant PROPOSER_THRESHOLD = 1;

    uint256 internal constant AVG_BLOCK_TIME = 12; // mirrors SeatToken.AVG_BLOCK_TIME

    bytes4 internal constant PROPOSE_SELECTOR = bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));
    bytes4 internal constant VOTE_SELECTOR = bytes4(keccak256("vote(address,uint256,uint8,(uint8,bytes)[],string)"));

    // ── sx-evm shared infra (deployed once in setUp; reused across every Space instance) ──
    ProxyFactory internal proxyFactory;
    Space internal spaceImpl;
    StubProposalValidation internal propValidation;
    address internal ozVotesStrategy;
    address internal ethTxAuthenticator;
    uint256 internal spaceSaltCounter;

    // ── SeatToken under test ──────────────────────────────────────────────────────────────
    SeatToken internal seatToken;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal burner = makeAddr("burner");
    address internal bootstrap = makeAddr("bootstrap");
    address internal expectedOwner = makeAddr("expectedOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        // block.timestamp = block.number + 1 invariant so ERC5805FutureLookup never trips
        // on getPastVotes during propose/vote flow.
        vm.roll(1);
        vm.warp(2);

        proxyFactory = new ProxyFactory();
        spaceImpl = new Space();
        propValidation = new StubProposalValidation();
        ozVotesStrategy = address(new OZVotesVotingStrategy());
        ethTxAuthenticator = address(new EthTxAuthenticator());

        seatToken = new SeatToken("PEN Seat", "SEAT", 10, 365 days, admin, minter, burner, bootstrap, expectedOwner);
    }

    // ── Non-Space unit tests (unchanged from the mock-era file) ───────────────────────────

    function test_MetadataAndRoles() public view {
        assertEq(seatToken.name(), "PEN Seat");
        assertEq(seatToken.symbol(), "SEAT");
        assertEq(seatToken.decimals(), 0);
        assertEq(seatToken.supplyCap(), 10);
        assertEq(seatToken.inactivityPeriod(), 365 days);
        assertEq(seatToken.bootstrap(), bootstrap);
        assertEq(seatToken.expectedOwner(), expectedOwner);

        assertTrue(seatToken.hasRole(seatToken.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(seatToken.hasRole(seatToken.MINTER_ROLE(), minter));
        assertTrue(seatToken.hasRole(seatToken.BURNER_ROLE(), burner));
    }

    function test_MintAutoDelegatesAndTracksVotes() public {
        uint256 mintBlock = block.number;

        vm.prank(minter);
        seatToken.mint(alice, 3);

        assertEq(seatToken.balanceOf(alice), 3);
        assertEq(seatToken.getVotes(alice), 3);
        assertEq(seatToken.delegates(alice), alice);
        assertEq(seatToken.lastActivityAt(alice), block.timestamp);

        vm.roll(mintBlock + 1);
        assertEq(seatToken.getPastVotes(alice, mintBlock), 3);
        assertEq(seatToken.getPastTotalSupply(mintBlock), 3);
    }

    function test_CannotTransferOrApprove() public {
        vm.prank(minter);
        seatToken.mint(alice, 2);

        vm.prank(alice);
        vm.expectRevert(SeatToken.TransfersDisabled.selector);
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        seatToken.transfer(bob, 1);

        vm.prank(alice);
        vm.expectRevert(SeatToken.TransfersDisabled.selector);
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        seatToken.transferFrom(alice, bob, 1);

        vm.prank(alice);
        vm.expectRevert(SeatToken.ApprovalsDisabled.selector);
        seatToken.approve(bob, 1);
    }

    function test_CannotDelegateToAnotherAccount() public {
        vm.prank(minter);
        seatToken.mint(alice, 2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SeatToken.NonSelfDelegation.selector, alice, bob));
        seatToken.delegate(bob);
    }

    function test_BurnClearsBalanceAndActivityWhenHolderExits() public {
        vm.startPrank(minter);
        seatToken.mint(alice, 2);
        vm.stopPrank();

        vm.prank(burner);
        seatToken.burn(alice, 2);

        assertEq(seatToken.balanceOf(alice), 0);
        assertEq(seatToken.getVotes(alice), 0);
        assertEq(seatToken.lastActivityAt(alice), 0);
    }

    // ── setSpace ──────────────────────────────────────────────────────────────────────────

    event SpaceLocked(address indexed space);

    function test_SetSpace_HappyPath_LocksAndClearsBootstrap() public {
        address space = _deployRealSpace(expectedOwner);

        vm.expectEmit(true, false, false, false);
        emit SpaceLocked(space);

        vm.prank(bootstrap);
        seatToken.setSpace(space);

        assertEq(seatToken.space(), space);
        assertTrue(seatToken.spaceLocked());
        assertEq(seatToken.bootstrap(), address(0));
    }

    function test_SetSpace_RevertsWhenCallerIsNotBootstrap() public {
        address space = _deployRealSpace(expectedOwner);

        vm.expectRevert(SeatToken.NotBootstrap.selector);
        vm.prank(alice);
        seatToken.setSpace(space);
    }

    function test_SetSpace_RevertsOnSecondCall() public {
        address first = _deployRealSpace(expectedOwner);
        address second = _deployRealSpace(expectedOwner);

        vm.prank(bootstrap);
        seatToken.setSpace(first);

        // Second call must revert regardless of caller — bootstrap slot is cleared, so a NotBootstrap
        // revert would also mask the SpaceAlreadyLocked guard. Assert the specific error surface.
        vm.expectRevert(SeatToken.SpaceAlreadyLocked.selector);
        vm.prank(bootstrap);
        seatToken.setSpace(second);
    }

    function test_SetSpace_RevertsOnZeroAddress() public {
        vm.expectRevert(SeatToken.InvalidSpace.selector);
        vm.prank(bootstrap);
        seatToken.setSpace(address(0));
    }

    function test_SetSpace_RevertsWhenTargetIsEOA() public {
        // A freshly-created address has no bytecode — the EOA case the guard defends against.
        address eoa = makeAddr("someEOA");

        vm.expectRevert(SeatToken.SpaceNotAContract.selector);
        vm.prank(bootstrap);
        seatToken.setSpace(eoa);
    }

    function test_SetSpace_RevertsWhenSpaceOwnerDoesNotMatchExpected() public {
        address wrongOwner = makeAddr("wrongOwner");
        address space = _deployRealSpace(wrongOwner);

        vm.expectRevert(abi.encodeWithSelector(SeatToken.UnexpectedSpaceOwner.selector, wrongOwner, expectedOwner));
        vm.prank(bootstrap);
        seatToken.setSpace(space);
    }

    // ── refreshActivity ───────────────────────────────────────────────────────────────────

    function test_RefreshActivity_RevertsBeforeSpaceIsSet() public {
        vm.expectRevert(SeatToken.SpaceNotSet.selector);
        seatToken.refreshActivity(alice, 1);
    }

    function test_RefreshActivity_RevertsForNonSeatHolder() public {
        _bindRealSpace();

        vm.expectRevert(abi.encodeWithSelector(SeatToken.NotSeatHolder.selector, alice));
        seatToken.refreshActivity(alice, 1);
    }

    function test_RefreshActivity_RevertsWhenVoterDidNotVote() public {
        _bindRealSpace();
        vm.prank(minter);
        seatToken.mint(alice, 1);

        // No vote cast anywhere — Space.voteRegistry[1][alice] is zero for a nonexistent
        // proposal, and refreshActivity reverts on the voteRegistry check before reading
        // proposals(), so we don't need a real proposal here.
        vm.expectRevert(abi.encodeWithSelector(SeatToken.NotVoted.selector, alice, uint256(1)));
        seatToken.refreshActivity(alice, 1);
    }

    function test_RefreshActivity_InsideWindowUsesBlockTimestamp() public {
        address space = _bindRealSpace();
        (uint256 proposalId,) = _mintProposeVote(space, alice);

        // Still inside the voting window — refresh should stamp `block.timestamp`.
        assertLe(block.number, ISpaceExec(space).proposals(proposalId).maxEndBlockNumber);
        seatToken.refreshActivity(alice, proposalId);

        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
    }

    // A refresh long after voting closed must NOT date activity to "now"; it must cap the
    // timestamp at approximately when voting closed, using AVG_BLOCK_TIME as the anchor.
    function test_RefreshActivity_CapsAtMaxEndBlockAfterWindowCloses() public {
        address space = _bindRealSpace();
        (uint256 proposalId, uint32 maxEndBlock) = _mintProposeVote(space, alice);

        // Move well past window close — long-tail refresh scenario.
        _advanceLockstep(1_000);
        uint256 blocksSinceClose = block.number - maxEndBlock;
        uint256 expected = block.timestamp - blocksSinceClose * AVG_BLOCK_TIME;

        seatToken.refreshActivity(alice, proposalId);

        assertEq(seatToken.lastActivityAt(alice), expected);
        assertLt(seatToken.lastActivityAt(alice), block.timestamp);
    }

    // A newer refresh must not overwrite a more-recent activity anchor. Common scenario:
    // holder self-refreshes on a new proposal, then a keeper later refreshes them against
    // an older proposal — the keeper call must not roll back their activity.
    function test_RefreshActivity_DoesNotMoveActivityBackwards() public {
        address space = _bindRealSpace();

        vm.prank(minter);
        seatToken.mint(alice, 1);
        _advanceLockstep(1);

        // Proposal 1 — first proposal in this Space; alice votes then we let its window close.
        uint256 oldId = _proposeAndVote(space, alice);
        _advanceLockstep(1_000);

        // Proposal 2 — new proposal against the same Space, alice votes again.
        uint256 newId = _proposeAndVote(space, alice);

        seatToken.refreshActivity(alice, newId);
        uint48 activityAfterFirst = seatToken.lastActivityAt(alice);

        // Refreshing against the OLD proposal should not roll activity back.
        seatToken.refreshActivity(alice, oldId);
        assertEq(seatToken.lastActivityAt(alice), activityAfterFirst);
    }

    // ── refreshActivityForProposal ────────────────────────────────────────────────────────

    function test_RefreshActivityForProposal_RevertsBeforeSpaceIsSet() public {
        vm.expectRevert(SeatToken.SpaceNotSet.selector);
        seatToken.refreshActivityForProposal(alice, 1);
    }

    function test_RefreshActivityForProposal_RevertsForNonSeatHolder() public {
        _bindRealSpace();
        vm.expectRevert(abi.encodeWithSelector(SeatToken.NotSeatHolder.selector, alice));
        seatToken.refreshActivityForProposal(alice, 1);
    }

    function test_RefreshActivityForProposal_RevertsWhenNotAuthor() public {
        address space = _bindRealSpace();
        vm.prank(minter);
        seatToken.mint(alice, 1);
        vm.prank(minter);
        seatToken.mint(bob, 1);
        _advanceLockstep(1);

        // Proposal authored by bob, not alice.
        uint256 proposalId = _propose(space, bob);

        vm.expectRevert(abi.encodeWithSelector(SeatToken.NotProposer.selector, alice, proposalId));
        seatToken.refreshActivityForProposal(alice, proposalId);
    }

    // Anchor is startBlockNumber (upper bound on proposal-creation moment). Long-tail refresh
    // caps activity at that block's timestamp rather than "now".
    function test_RefreshActivityForProposal_CapsAtStartBlockAfterWindowCloses() public {
        address space = _bindRealSpace();
        vm.prank(minter);
        seatToken.mint(alice, 1);
        _advanceLockstep(1);

        uint256 proposalId = _propose(space, alice);
        uint32 startBlock = ISpaceExec(space).proposals(proposalId).startBlockNumber;

        _advanceLockstep(1_000);
        uint256 secondsSince = (block.number - startBlock) * AVG_BLOCK_TIME;
        uint256 expected = block.timestamp - secondsSince;

        seatToken.refreshActivityForProposal(alice, proposalId);

        assertEq(seatToken.lastActivityAt(alice), expected);
        assertLt(seatToken.lastActivityAt(alice), block.timestamp);
    }

    // ── refreshActivityForProposalVoters ──────────────────────────────────────────────────

    function test_RefreshActivityForProposalVoters_RefreshesAllValidVoters() public {
        address space = _bindRealSpace();
        vm.prank(minter);
        seatToken.mint(alice, 1);
        vm.prank(minter);
        seatToken.mint(bob, 1);
        _advanceLockstep(1);

        uint256 proposalId = _propose(space, alice);
        _advanceLockstep(VOTING_DELAY + 1);
        _vote(space, alice, proposalId, Choice.For);
        _vote(space, bob, proposalId, Choice.For);

        _advanceLockstep(1); // advance past the mint's activity timestamp

        address[] memory voters = new address[](2);
        voters[0] = alice;
        voters[1] = bob;
        seatToken.refreshActivityForProposalVoters(proposalId, voters);

        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
        assertEq(seatToken.lastActivityAt(bob), block.timestamp);
    }

    // Non-seatholders and non-voters must be silently skipped rather than reverting the whole batch.
    function test_RefreshActivityForProposalVoters_SkipsInvalidEntries() public {
        address space = _bindRealSpace();
        address charlie = makeAddr("charlie");

        vm.prank(minter);
        seatToken.mint(alice, 1);
        vm.prank(minter);
        seatToken.mint(charlie, 1);
        _advanceLockstep(1);

        uint256 proposalId = _propose(space, alice);
        _advanceLockstep(VOTING_DELAY + 1);
        _vote(space, alice, proposalId, Choice.For);
        // charlie has balance but never voted; bob has no balance and never voted.

        _advanceLockstep(1);

        address[] memory voters = new address[](3);
        voters[0] = alice;
        voters[1] = bob;
        voters[2] = charlie;
        seatToken.refreshActivityForProposalVoters(proposalId, voters);

        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
        assertEq(seatToken.lastActivityAt(bob), 0);
        // charlie's activity stays at his mint timestamp — not current block.
        assertLt(seatToken.lastActivityAt(charlie), block.timestamp);
    }

    // ── refreshActivityBatch ──────────────────────────────────────────────────────────────

    function test_RefreshActivityBatch_RefreshesMixedProposals() public {
        address space = _bindRealSpace();

        vm.prank(minter);
        seatToken.mint(alice, 1);
        vm.prank(minter);
        seatToken.mint(bob, 1);
        _advanceLockstep(1);

        uint256 id1 = _propose(space, alice);
        _advanceLockstep(VOTING_DELAY + 1);
        _vote(space, alice, id1, Choice.For);
        _advanceLockstep(MAX_VOTING_DURATION); // let id1 close

        uint256 id2 = _propose(space, bob);
        _advanceLockstep(VOTING_DELAY + 1);
        _vote(space, bob, id2, Choice.For);

        _advanceLockstep(1);

        address[] memory voters = new address[](2);
        voters[0] = alice;
        voters[1] = bob;
        uint256[] memory proposalIds = new uint256[](2);
        proposalIds[0] = id1;
        proposalIds[1] = id2;
        seatToken.refreshActivityBatch(voters, proposalIds);

        // Anti-farm bound applies to alice's id1 (window closed); bob's id2 is still open.
        assertGt(seatToken.lastActivityAt(alice), 0);
        assertEq(seatToken.lastActivityAt(bob), block.timestamp);
    }

    function test_RefreshActivityBatch_RevertsOnLengthMismatch() public {
        _bindRealSpace();

        address[] memory voters = new address[](2);
        voters[0] = alice;
        voters[1] = bob;
        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = 1;

        vm.expectRevert(SeatToken.InvalidBatchInput.selector);
        seatToken.refreshActivityBatch(voters, proposalIds);
    }

    function test_RefreshActivityBatch_SkipsInvalidEntries() public {
        address space = _bindRealSpace();
        vm.prank(minter);
        seatToken.mint(alice, 1);
        _advanceLockstep(1);

        uint256 proposalId = _propose(space, alice);
        _advanceLockstep(VOTING_DELAY + 1);
        _vote(space, alice, proposalId, Choice.For);

        _advanceLockstep(1);

        address[] memory voters = new address[](3);
        voters[0] = alice;
        voters[1] = bob; // no balance
        voters[2] = alice; // has balance but never voted on id 99
        uint256[] memory proposalIds = new uint256[](3);
        proposalIds[0] = proposalId;
        proposalIds[1] = proposalId; // bob would-be voter but no balance
        proposalIds[2] = 99; // alice never voted on 99

        seatToken.refreshActivityBatch(voters, proposalIds);

        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
        assertEq(seatToken.lastActivityAt(bob), 0);
    }

    // ── cross-space isolation ─────────────────────────────────────────────────────────────

    // Votes on a *different* real Space (never bound via setSpace) must not count as activity
    // on this SeatToken. Direct on-chain proof of the "wrong Space forgery is not possible"
    // security property from Design Decision #1.
    function test_RefreshActivity_IgnoresVotesOnOtherSpace() public {
        _bindRealSpace(); // this is the bound Space; refreshActivity always reads its voteRegistry
        address other = _deployRealSpace(expectedOwner);

        vm.prank(minter);
        seatToken.mint(alice, 1);
        _advanceLockstep(1);

        // Alice votes ONLY on the "other" Space. The bound Space has no such vote.
        uint256 otherProposalId = _propose(other, alice);
        _advanceLockstep(VOTING_DELAY + 1);
        _vote(other, alice, otherProposalId, Choice.For);

        // refreshActivity reads the bound Space's voteRegistry — sees zero → reverts NotVoted.
        vm.expectRevert(abi.encodeWithSelector(SeatToken.NotVoted.selector, alice, otherProposalId));
        seatToken.refreshActivity(alice, otherProposalId);
    }

    // ── pre-bootstrap gap ─────────────────────────────────────────────────────────────────

    // Between construction and setSpace, refresh* must all revert while mint / isInactive /
    // balance reads work normally. Guards against a future maintainer adding a Space-dependency
    // to some other function.
    function test_PreBootstrap_MintAndReadsWorkButRefreshReverts() public {
        // No setSpace called — spaceLocked is still false.
        vm.prank(minter);
        seatToken.mint(alice, 1);

        assertEq(seatToken.balanceOf(alice), 1);
        assertFalse(seatToken.isInactive(alice));

        address[] memory voters = new address[](1);
        voters[0] = alice;
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.expectRevert(SeatToken.SpaceNotSet.selector);
        seatToken.refreshActivity(alice, 1);

        vm.expectRevert(SeatToken.SpaceNotSet.selector);
        seatToken.refreshActivityForProposal(alice, 1);

        vm.expectRevert(SeatToken.SpaceNotSet.selector);
        seatToken.refreshActivityForProposalVoters(1, voters);

        vm.expectRevert(SeatToken.SpaceNotSet.selector);
        seatToken.refreshActivityBatch(voters, ids);
    }

    // Guardrail (not a runtime check): pins the current mainnet block-time assumption so any
    // redeploy on a different chain has to deliberately edit both the constant and this test.
    // See `docs/future-refresh-activity.md` §"The block-time approximation".
    function test_AvgBlockTimeMatchesMainnetAssumption() public view {
        assertEq(seatToken.AVG_BLOCK_TIME(), 12);
    }

    function test_RevertWhenMintExceedsSupplyCap() public {
        vm.prank(minter);
        seatToken.mint(alice, 10);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(ERC20Votes.ERC20ExceededSafeSupply.selector, 11, 10));
        seatToken.mint(bob, 1);
    }

    // ── Real-Space deploy helpers ─────────────────────────────────────────────────────────

    /// @dev Deploys a fresh sx-evm Space via ProxyFactory with the given owner. Every call
    ///      bumps the salt so multiple Spaces can co-exist in one test (used by the
    ///      cross-Space isolation and second-call-reverts tests).
    function _deployRealSpace(address owner_) internal returns (address space) {
        spaceSaltCounter++;
        SpaceInit.Params memory params = SpaceInit.Params({
            owner: owner_,
            seatToken: address(seatToken),
            ozVotesStrategy: ozVotesStrategy,
            proposalValidationStrategy: Strategy({
                addr: address(propValidation), params: abi.encode(uint256(PROPOSER_THRESHOLD), address(seatToken))
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
        proxyFactory.deployProxy(address(spaceImpl), SpaceInit.encodeInitializeCall(init), spaceSaltCounter);

        bytes32 salt = keccak256(abi.encodePacked(address(this), spaceSaltCounter));
        space = proxyFactory.predictProxyAddress(address(spaceImpl), salt);
    }

    /// @dev Deploys a Space with owner=expectedOwner and binds it via `SeatToken.setSpace`.
    function _bindRealSpace() internal returns (address space) {
        space = _deployRealSpace(expectedOwner);
        vm.prank(bootstrap);
        seatToken.setSpace(space);
    }

    // Advance (block.number, block.timestamp) in lockstep by AVG_BLOCK_TIME seconds per block,
    // so tests see the same block/timestamp relationship as post-merge mainnet.
    function _advanceLockstep(uint256 blocksToAdvance) internal {
        vm.roll(block.number + blocksToAdvance);
        vm.warp(block.timestamp + blocksToAdvance * AVG_BLOCK_TIME);
    }

    // ── Real propose / vote helpers ───────────────────────────────────────────────────────

    function _defaultUserStrategies() internal pure returns (IndexedStrategy[] memory strats) {
        strats = new IndexedStrategy[](1);
        strats[0] = IndexedStrategy({index: 0, params: ""});
    }

    /// @dev Real propose through the stock `EthTxAuthenticator`. The `proposer` must hold
    ///      seat(s) at snapshot time and be minted at least one block before this call.
    function _propose(address space, address proposer) internal returns (uint256 id) {
        id = ISpaceExec(space).nextProposalId();
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({to: address(0xdead), value: 0, data: "", operation: Enum.Operation.Call, salt: 0});
        bytes memory payload = abi.encode(txs);
        // Dummy exec strategy address — these unit tests never execute proposals.
        bytes memory data = abi.encode(
            proposer, "", Strategy({addr: address(0xbeef), params: payload}), abi.encode(_defaultUserStrategies())
        );
        vm.prank(proposer);
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, PROPOSE_SELECTOR, data);
    }

    /// @dev Real vote through the stock `EthTxAuthenticator`. Voter must have seats at the
    ///      proposal's snapshot block and the call must land inside the voting window.
    function _vote(address space, address voter, uint256 proposalId, Choice choice) internal {
        bytes memory data = abi.encode(voter, proposalId, choice, _defaultUserStrategies(), "");
        vm.prank(voter);
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, VOTE_SELECTOR, data);
    }

    /// @dev Full mint→propose→advance-into-window→vote flow that populates a proposal + its
    ///      voteRegistry entry for a single voter. Returns (proposalId, maxEndBlockNumber).
    function _mintProposeVote(address space, address voter) internal returns (uint256 proposalId, uint32 maxEndBlock) {
        vm.prank(minter);
        seatToken.mint(voter, 1);
        _advanceLockstep(1);
        proposalId = _propose(space, voter);
        _advanceLockstep(VOTING_DELAY + 1);
        _vote(space, voter, proposalId, Choice.For);
        maxEndBlock = ISpaceExec(space).proposals(proposalId).maxEndBlockNumber;
    }

    /// @dev Assumes `voter` is already minted and warmed up. Proposes + votes + returns id.
    function _proposeAndVote(address space, address voter) internal returns (uint256 proposalId) {
        proposalId = _propose(space, voter);
        _advanceLockstep(VOTING_DELAY + 1);
        _vote(space, voter, proposalId, Choice.For);
    }
}
