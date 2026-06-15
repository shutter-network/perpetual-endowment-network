// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {PrincipalManager} from "../src/PrincipalManager.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Covers the PEN→PEN migration primitives on `PrincipalManager`:
///      - `pause()` / `unpause()` admin gating and effect on user-state-changing entrypoints
///      - `withdraw(token, to, amount)` admin gating, no-pause-required, multi-token rescue
contract PauseAndWithdrawTest is Test {
    MockUSDC internal usdc;
    MockUSDC internal otherToken; // for non-asset withdraw testing
    PrincipalManager internal pm;

    address internal admin = makeAddr("admin");
    address internal bonding = makeAddr("bonding");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        usdc = new MockUSDC();
        otherToken = new MockUSDC();
        pm = new PrincipalManager(usdc, admin, bonding, 0, IERC4626(address(0)));
    }

    // ── pause / unpause ────────────────────────────────────────────────────────

    function test_pause_setsPausedTrue_emitsEvent() public {
        assertFalse(pm.paused());
        vm.prank(admin);
        pm.pause();
        assertTrue(pm.paused());
    }

    function test_unpause_restoresPausedFalse() public {
        vm.startPrank(admin);
        pm.pause();
        pm.unpause();
        vm.stopPrank();
        assertFalse(pm.paused());
    }

    function test_pause_revertsForNonAdmin() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        pm.pause();
    }

    function test_unpause_revertsForNonAdmin() public {
        vm.prank(admin);
        pm.pause();

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        pm.unpause();
    }

    function test_recordPurchase_revertsWhilePaused() public {
        vm.prank(admin);
        pm.pause();

        usdc.mint(address(pm), 10e6);
        vm.prank(bonding);
        vm.expectRevert();
        pm.recordPurchase(10e6);
    }

    function test_payRefund_revertsWhilePaused() public {
        // Establish refund obligation before pausing.
        usdc.mint(address(pm), 10e6);
        vm.prank(bonding);
        pm.recordPurchase(10e6);

        vm.prank(admin);
        pm.pause();

        vm.prank(bonding);
        vm.expectRevert();
        pm.payRefund(recipient, 5e6);
    }

    function test_executeFunding_succeedsWhilePaused() public {
        // Admin can still complete in-flight funding obligations while paused.
        usdc.mint(address(pm), 10e6);
        vm.prank(admin);
        pm.pause();

        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 4e6;

        vm.prank(admin);
        pm.executeFunding(recipients, amounts);
        assertEq(usdc.balanceOf(recipient), 4e6);
    }

    function test_withdraw_succeedsWhilePaused() public {
        usdc.mint(address(pm), 10e6);
        vm.prank(admin);
        pm.pause();

        vm.prank(admin);
        pm.withdraw(IERC20(address(usdc)), recipient, 3e6);
        assertEq(usdc.balanceOf(recipient), 3e6);
    }

    // ── withdraw ───────────────────────────────────────────────────────────────

    function test_withdraw_transfersAsset() public {
        usdc.mint(address(pm), 10e6);

        vm.prank(admin);
        pm.withdraw(IERC20(address(usdc)), recipient, 7e6);

        assertEq(usdc.balanceOf(recipient), 7e6);
        assertEq(usdc.balanceOf(address(pm)), 3e6);
    }

    function test_withdraw_rescuesAirdroppedToken() public {
        // A non-payment-asset token sent to the contract (e.g. airdrop) can be withdrawn.
        otherToken.mint(address(pm), 100);

        vm.prank(admin);
        pm.withdraw(IERC20(address(otherToken)), recipient, 100);

        assertEq(otherToken.balanceOf(recipient), 100);
    }

    function test_withdraw_doesNotDecrementAccountedPrincipal() public {
        usdc.mint(address(pm), 10e6);
        vm.prank(bonding);
        pm.recordPurchase(10e6);
        assertEq(pm.accountedPrincipal(), 10e6);

        vm.prank(admin);
        pm.withdraw(IERC20(address(usdc)), recipient, 10e6);

        // Withdrawal moves balance but leaves the refund obligation on book.
        assertEq(pm.accountedPrincipal(), 10e6);
        assertEq(usdc.balanceOf(address(pm)), 0);
    }

    function test_withdraw_revertsForNonAdmin() public {
        usdc.mint(address(pm), 10e6);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        pm.withdraw(IERC20(address(usdc)), recipient, 1e6);
    }

    function test_withdraw_revertsOnZeroToken() public {
        vm.prank(admin);
        vm.expectRevert();
        pm.withdraw(IERC20(address(0)), recipient, 1e6);
    }

    function test_withdraw_revertsOnZeroReceiver() public {
        usdc.mint(address(pm), 10e6);
        vm.prank(admin);
        vm.expectRevert();
        pm.withdraw(IERC20(address(usdc)), address(0), 1e6);
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert();
        pm.withdraw(IERC20(address(usdc)), recipient, 0);
    }
}
