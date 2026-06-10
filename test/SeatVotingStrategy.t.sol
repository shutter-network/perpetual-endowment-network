// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {SeatVotingStrategy} from "../src/governance/SeatVotingStrategy.sol";

/// @dev SeatToken now uses block.number as its ERC20Votes clock (OZ v5 default).
///      These tests reflect that: all snapshots use block numbers, advances use vm.roll.
contract SeatVotingStrategyTest is Test {
    SeatToken internal seatToken;
    SeatVotingStrategy internal strategy;

    address internal minter = makeAddr("minter");
    address internal burner = makeAddr("burner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.roll(1);
        seatToken = new SeatToken("PEN Seat", "SEAT", 1000, 365 days, address(this), minter, burner, address(0));
        strategy = new SeatVotingStrategy();
    }

    function _params() internal view returns (bytes memory) {
        return abi.encode(address(seatToken));
    }

    function _getVotingPower(uint32 blockNum, address voter) internal view returns (uint256) {
        return strategy.getVotingPower(blockNum, voter, _params(), "");
    }

    function test_singleSeatHolder_hasOnePower() public {
        uint32 mintBlock = uint32(block.number);
        vm.prank(minter);
        seatToken.mint(alice, 1);

        vm.roll(block.number + 1);
        assertEq(_getVotingPower(mintBlock, alice), 1);
    }

    function test_multiSeatHolder_hasNPower() public {
        uint32 mintBlock = uint32(block.number);
        vm.prank(minter);
        seatToken.mint(alice, 7);

        vm.roll(block.number + 1);
        assertEq(_getVotingPower(mintBlock, alice), 7);
    }

    function test_zeroSeats_hasZeroPower() public {
        uint32 bn = uint32(block.number);
        vm.roll(block.number + 1);
        assertEq(_getVotingPower(bn, alice), 0);
    }

    function test_pastBlockNumber_unaffectedByLaterMint() public {
        vm.roll(100);
        vm.prank(minter);
        seatToken.mint(alice, 2);

        vm.roll(200);
        vm.prank(minter);
        seatToken.mint(alice, 3); // alice now has 5

        vm.roll(300);
        assertEq(_getVotingPower(100, alice), 2); // snapshot at block 100: first mint only
        assertEq(_getVotingPower(200, alice), 5); // snapshot at block 200: both mints
        assertEq(_getVotingPower(150, alice), 2); // between mints: still 2
    }

    function test_pastBlockNumber_unaffectedByLaterBurn() public {
        vm.roll(100);
        vm.prank(minter);
        seatToken.mint(alice, 3);

        vm.roll(200);
        vm.prank(burner);
        seatToken.burn(alice, 2); // alice now has 1

        vm.roll(300);
        assertEq(_getVotingPower(100, alice), 3); // before burn
        assertEq(_getVotingPower(200, alice), 1); // after burn
        assertEq(_getVotingPower(150, alice), 3); // between mint and burn: still 3
    }

    function test_revertsOnMalformedParams() public {
        uint32 bn = uint32(block.number);
        vm.roll(block.number + 1);
        vm.expectRevert();
        strategy.getVotingPower(bn, alice, bytes(""), "");
    }

    // PropositionPower (sx-evm) passes uint32(block.number) to getVotingPower for proposal
    // validation. OZ v5 getPastVotes rejects timepoint >= clock(). SeatVotingStrategy caps
    // to block.number - 1 instead of propagating the revert, so validation always works.
    function test_currentBlockIsCappedToPreviousBlock() public {
        vm.roll(5);
        vm.prank(minter);
        seatToken.mint(alice, 1);

        vm.roll(6);
        // block.number == 6; passing 6 is capped to 5. Alice minted at block 5 → returns 1.
        assertEq(_getVotingPower(uint32(block.number), alice), 1);
    }
}
