// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Choice, IndexedStrategy, Strategy} from "@snapshot-x/types.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {PENTxAuthenticator} from "../src/governance/PENTxAuthenticator.sol";
import {ISeatToken} from "../src/interfaces/ISeatToken.sol";

/// @dev Minimal Space mock. Accepts any call via fallback; can be configured to revert.
contract MockSpace {
    error Rejected();

    bool public rejectAll;

    function setRejectAll(bool val) external {
        rejectAll = val;
    }

    fallback() external {
        if (rejectAll) revert Rejected();
    }
}

contract PENTxAuthenticatorTest is Test {
    // Mirror of Authenticator internal constants (used to build calldata in tests).
    bytes4 internal constant PROPOSE_SELECTOR =
        bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));
    bytes4 internal constant VOTE_SELECTOR =
        bytes4(keccak256("vote(address,uint256,uint8,(uint8,bytes)[],string)"));
    bytes4 internal constant UPDATE_PROPOSAL_SELECTOR =
        bytes4(keccak256("updateProposal(address,uint256,(address,bytes),string)"));
    bytes4 internal constant BAD_SELECTOR = bytes4(keccak256("unknown()"));

    SeatToken internal seatToken;
    PENTxAuthenticator internal authenticator;
    MockSpace internal mockSpace;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        // Test contract is admin and minter for simplicity.
        seatToken = new SeatToken("PEN Seat", "SEAT", 1000, 365 days, address(this), address(this), address(0), address(0));
        authenticator = new PENTxAuthenticator(ISeatToken(address(seatToken)));
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), address(authenticator));
        mockSpace = new MockSpace();
    }

    // -- calldata helpers -----------------------------------------------------

    function _proposeData(address author) internal pure returns (bytes memory) {
        return abi.encode(author, "", Strategy({addr: address(0), params: ""}), bytes(""));
    }

    function _voteData(address voter, Choice choice) internal pure returns (bytes memory) {
        return abi.encode(voter, uint256(0), choice, new IndexedStrategy[](0));
    }

    function _updateProposalData(address author) internal pure returns (bytes memory) {
        return abi.encode(author, uint256(0), Strategy({addr: address(0), params: ""}), "");
    }

    // -- tests ----------------------------------------------------------------

    function test_authenticate_vote_recordsActivity() public {
        seatToken.mint(alice, 1);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        authenticator.authenticate(address(mockSpace), VOTE_SELECTOR, _voteData(alice, Choice.For));

        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
    }

    function test_authenticate_propose_recordsActivity() public {
        seatToken.mint(alice, 1);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        authenticator.authenticate(address(mockSpace), PROPOSE_SELECTOR, _proposeData(alice));

        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
    }

    function test_authenticate_updateProposal_recordsActivity() public {
        seatToken.mint(alice, 1);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        authenticator.authenticate(address(mockSpace), UPDATE_PROPOSAL_SELECTOR, _updateProposalData(alice));

        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
    }

    function test_authenticate_abstainVote_recordsActivity() public {
        seatToken.mint(alice, 1);
        vm.warp(block.timestamp + 100);

        vm.prank(alice);
        authenticator.authenticate(address(mockSpace), VOTE_SELECTOR, _voteData(alice, Choice.Abstain));

        // Abstain counts as activity — choice value is irrelevant to recording.
        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
    }

    function test_authenticate_revertsOnWrongMsgSender() public {
        seatToken.mint(alice, 1);
        // Bob sends calldata that claims alice is the voter.
        vm.prank(bob);
        vm.expectRevert(PENTxAuthenticator.InvalidMessageSender.selector);
        authenticator.authenticate(address(mockSpace), VOTE_SELECTOR, _voteData(alice, Choice.For));
    }

    function test_authenticate_zeroSeats_succeedsWithoutRecordingActivity() public {
        // alice has no seats — authenticate should forward the call but skip recordActivity.
        vm.prank(alice);
        authenticator.authenticate(address(mockSpace), VOTE_SELECTOR, _voteData(alice, Choice.For));

        assertEq(seatToken.lastActivityAt(alice), 0);
    }

    function test_authenticate_spaceReverts_activityNotRecorded() public {
        seatToken.mint(alice, 1);
        uint48 activityBefore = seatToken.lastActivityAt(alice);

        vm.warp(block.timestamp + 100);
        mockSpace.setRejectAll(true);

        vm.expectRevert(MockSpace.Rejected.selector);
        vm.prank(alice);
        authenticator.authenticate(address(mockSpace), VOTE_SELECTOR, _voteData(alice, Choice.For));

        // Entire call reverted — lastActivityAt must be unchanged.
        assertEq(seatToken.lastActivityAt(alice), activityBefore);
    }

    function test_authenticate_revertsOnBadSelector() public {
        vm.prank(alice);
        vm.expectRevert(PENTxAuthenticator.InvalidFunctionSelector.selector);
        authenticator.authenticate(address(mockSpace), BAD_SELECTOR, bytes(""));
    }
}
