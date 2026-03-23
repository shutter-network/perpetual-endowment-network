// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract BondingTrancheTest is Test {
    uint256 internal constant REFUND_PRICE = 0.5e6;

    MockUSDC internal usdc;
    SeatToken internal seatToken;
    PrincipalManager internal principalManager;
    BondingTranche internal bondingTranche;

    address internal admin = makeAddr("admin");
    address internal reclaimer = makeAddr("reclaimer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
        seatToken = new SeatToken("PEN Seat", "SEAT", 10, 365 days, admin, address(0), address(0), address(0));
        principalManager = new PrincipalManager(usdc, admin, address(0), 0, IERC4626(address(0)), IERC4626(address(0)), address(0));

        uint256[] memory upperBounds = new uint256[](3);
        uint256[] memory prices = new uint256[](3);
        upperBounds[0] = 3;
        upperBounds[1] = 7;
        upperBounds[2] = 10;
        prices[0] = 1e6;
        prices[1] = 2e6;
        prices[2] = 3e6;

        bondingTranche =
            new BondingTranche(seatToken, principalManager, REFUND_PRICE, admin, reclaimer, upperBounds, prices);

        vm.startPrank(admin);
        seatToken.grantRole(seatToken.MINTER_ROLE(), address(bondingTranche));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));
        principalManager.grantRole(principalManager.BONDING_ROLE(), address(bondingTranche));
        vm.stopPrank();
    }

    function test_QuotePurchaseAcrossTranches() public view {
        assertEq(bondingTranche.quotePurchase(2), 2e6);
        assertEq(bondingTranche.quotePurchase(5), 7e6);
    }

    function test_PurchaseMintsSeatsAndRoutesFundsToPrincipalManager() public {
        usdc.mint(alice, 10e6);

        vm.prank(alice);
        usdc.approve(address(bondingTranche), 10e6);

        vm.prank(alice);
        uint256 totalCost = bondingTranche.purchase(alice, 4, 5e6);

        assertEq(totalCost, 5e6);
        assertEq(seatToken.balanceOf(alice), 4);
        assertEq(seatToken.getVotes(alice), 4);
        assertEq(principalManager.accountedPrincipal(), 5e6);
        assertEq(usdc.balanceOf(address(principalManager)), 5e6);
        assertEq(usdc.balanceOf(alice), 5e6);
    }

    function test_PurchaseAutoDepositsExcessIntoVault() public {
        ERC4626Mock vault = new ERC4626Mock(address(usdc));

        vm.startPrank(admin);
        principalManager.setPrincipalVault(vault);
        principalManager.setLiquidReserveTarget(1e6);
        vm.stopPrank();

        usdc.mint(alice, 10e6);

        vm.prank(alice);
        usdc.approve(address(bondingTranche), 10e6);

        vm.prank(alice);
        bondingTranche.purchase(alice, 4, 5e6);

        assertEq(principalManager.liquidAssets(), 1e6);
        assertEq(principalManager.deployedAssets(), 4e6);
        assertEq(principalManager.totalManagedAssets(), 5e6);
    }

    function test_RefundBurnsSeatsAndPaysFixedPrice() public {
        usdc.mint(alice, 10e6);

        vm.startPrank(alice);
        usdc.approve(address(bondingTranche), 10e6);
        bondingTranche.purchase(alice, 4, 5e6);
        vm.stopPrank();

        vm.prank(alice);
        uint256 refundAmount = bondingTranche.refund(2, alice);

        assertEq(refundAmount, 1e6);
        assertEq(seatToken.balanceOf(alice), 2);
        assertEq(principalManager.accountedPrincipal(), 4e6);
        assertEq(usdc.balanceOf(alice), 6e6);
        assertEq(usdc.balanceOf(address(principalManager)), 4e6);
        assertEq(bondingTranche.currentSeatPrice(), 1e6);
    }

    function test_ReclaimBurnsInactiveSeatsWithoutPayout() public {
        usdc.mint(alice, 5e6);

        vm.startPrank(alice);
        usdc.approve(address(bondingTranche), 5e6);
        bondingTranche.purchase(alice, 3, 3e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 366 days);

        vm.prank(reclaimer);
        uint256 reclaimedSeats = bondingTranche.reclaim(alice);

        assertEq(reclaimedSeats, 3);
        assertEq(seatToken.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 2e6);
        assertEq(usdc.balanceOf(address(principalManager)), 3e6);
        assertEq(bondingTranche.currentSeatPrice(), 1e6);
    }

    function test_PurchaseRevertsWhenCostExceedsUserLimit() public {
        usdc.mint(alice, 10e6);

        vm.prank(alice);
        usdc.approve(address(bondingTranche), 10e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondingTranche.PurchaseCostExceedsLimit.selector, 5e6, 4e6));
        bondingTranche.purchase(alice, 4, 4e6);
    }

    function test_ReclaimRevertsWhileHolderIsActive() public {
        usdc.mint(alice, 5e6);

        vm.startPrank(alice);
        usdc.approve(address(bondingTranche), 5e6);
        bondingTranche.purchase(alice, 1, 1e6);
        vm.stopPrank();

        vm.prank(reclaimer);
        vm.expectRevert(abi.encodeWithSelector(BondingTranche.HolderStillActive.selector, alice));
        bondingTranche.reclaim(alice);
    }
}
