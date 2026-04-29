// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Votes} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Votes.sol";

import {SeatToken} from "../src/SeatToken.sol";

contract SeatTokenTest is Test {
    SeatToken internal seatToken;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal burner = makeAddr("burner");
    address internal activityUpdater = makeAddr("activityUpdater");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        seatToken = new SeatToken("PEN Seat", "SEAT", 10, 365 days, admin, minter, burner, activityUpdater);
    }

    function test_MetadataAndRoles() public view {
        assertEq(seatToken.name(), "PEN Seat");
        assertEq(seatToken.symbol(), "SEAT");
        assertEq(seatToken.decimals(), 0);
        assertEq(seatToken.supplyCap(), 10);
        assertEq(seatToken.inactivityPeriod(), 365 days);

        assertTrue(seatToken.hasRole(seatToken.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(seatToken.hasRole(seatToken.MINTER_ROLE(), minter));
        assertTrue(seatToken.hasRole(seatToken.BURNER_ROLE(), burner));
        assertTrue(seatToken.hasRole(seatToken.ACTIVITY_ROLE(), activityUpdater));
    }

    function test_MintAutoDelegatesAndTracksVotes() public {
        uint256 mintTimestamp = block.timestamp;

        vm.prank(minter);
        seatToken.mint(alice, 3);

        assertEq(seatToken.balanceOf(alice), 3);
        assertEq(seatToken.getVotes(alice), 3);
        assertEq(seatToken.delegates(alice), alice);
        assertEq(seatToken.lastActivityAt(alice), block.timestamp);

        vm.warp(mintTimestamp + 1);
        assertEq(seatToken.getPastVotes(alice, mintTimestamp), 3);
        assertEq(seatToken.getPastTotalSupply(mintTimestamp), 3);
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

    function test_ActivityUpdaterCanRefreshActivity() public {
        vm.prank(minter);
        seatToken.mint(alice, 1);

        vm.warp(block.timestamp + 366 days);
        assertTrue(seatToken.isInactive(alice));

        vm.prank(activityUpdater);
        seatToken.recordActivity(alice);

        assertFalse(seatToken.isInactive(alice));
        assertEq(seatToken.lastActivityAt(alice), block.timestamp);
    }

    function test_RecordActivityRevertsForNonHolder() public {
        vm.prank(activityUpdater);
        vm.expectRevert(abi.encodeWithSelector(SeatToken.NotSeatHolder.selector, alice));
        seatToken.recordActivity(alice);
    }

    function test_RevertWhenMintExceedsSupplyCap() public {
        vm.prank(minter);
        seatToken.mint(alice, 10);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(ERC20Votes.ERC20ExceededSafeSupply.selector, 11, 10));
        seatToken.mint(bob, 1);
    }
}
