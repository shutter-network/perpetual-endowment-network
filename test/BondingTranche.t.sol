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
        principalManager = new PrincipalManager(usdc, admin, address(0), 0, IERC4626(address(0)));

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

    function test_ExtendTranchesReopensSalesBeyondInitialCap() public {
        MockUSDC usdc2 = new MockUSDC();
        address admin2 = makeAddr("admin2");
        address reclaimer2 = makeAddr("reclaimer2");
        address alice2 = makeAddr("alice2");

        // SeatToken cap can be larger than the initial tranche sale cap.
        SeatToken seatToken2 =
            new SeatToken("PEN Seat", "SEAT", 100, 365 days, admin2, address(0), address(0), address(0));
        PrincipalManager principalManager2 = new PrincipalManager(usdc2, admin2, address(0), 0, IERC4626(address(0)));

        uint256[] memory upperBounds = new uint256[](3);
        uint256[] memory prices = new uint256[](3);
        upperBounds[0] = 3;
        upperBounds[1] = 7;
        upperBounds[2] = 10; // initial sale cap at 10 seats
        prices[0] = 1e6;
        prices[1] = 2e6;
        prices[2] = 3e6;

        BondingTranche tranche2 =
            new BondingTranche(seatToken2, principalManager2, REFUND_PRICE, admin2, reclaimer2, upperBounds, prices);

        vm.startPrank(admin2);
        seatToken2.grantRole(seatToken2.MINTER_ROLE(), address(tranche2));
        seatToken2.grantRole(seatToken2.BURNER_ROLE(), address(tranche2));
        principalManager2.grantRole(principalManager2.BONDING_ROLE(), address(tranche2));
        vm.stopPrank();

        // Buy out the initial cap (10 seats total).
        usdc2.mint(alice2, 100e6);
        vm.startPrank(alice2);
        usdc2.approve(address(tranche2), 100e6);
        tranche2.purchase(alice2, 10, 30e6);
        vm.stopPrank();

        // Further purchases are sold out until governance extends tranches.
        vm.expectRevert(abi.encodeWithSelector(BondingTranche.InsufficientSeatsAvailable.selector, 1, 0));
        tranche2.quotePurchase(1);

        // Governance extends the sale cap from 10 -> 12 with a new price tier.
        uint256[] memory newUpperBounds = new uint256[](1);
        uint256[] memory newPrices = new uint256[](1);
        newUpperBounds[0] = 12;
        newPrices[0] = 5e6;

        vm.prank(admin2);
        tranche2.extendTranches(newUpperBounds, newPrices);

        // Sales resume for seats 11-12 at the new price.
        assertEq(tranche2.quotePurchase(1), 5e6);

        usdc2.mint(alice2, 10e6);
        vm.startPrank(alice2);
        usdc2.approve(address(tranche2), 10e6);
        tranche2.purchase(alice2, 2, 10e6);
        vm.stopPrank();

        assertEq(seatToken2.totalSupply(), 12);
        assertEq(seatToken2.balanceOf(alice2), 12);
    }

    function test_ExtendTranchesValidatesInputs() public {
        MockUSDC usdc2 = new MockUSDC();
        address admin2 = makeAddr("admin2");
        address reclaimer2 = makeAddr("reclaimer2");
        address alice2 = makeAddr("alice2");

        // SeatToken cap can be larger than the initial tranche sale cap.
        SeatToken seatToken2 =
            new SeatToken("PEN Seat", "SEAT", 100, 365 days, admin2, address(0), address(0), address(0));
        PrincipalManager principalManager2 = new PrincipalManager(usdc2, admin2, address(0), 0, IERC4626(address(0)));

        uint256[] memory upperBounds = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        upperBounds[0] = 10;
        prices[0] = 1e6;

        BondingTranche tranche2 =
            new BondingTranche(seatToken2, principalManager2, REFUND_PRICE, admin2, reclaimer2, upperBounds, prices);

        vm.startPrank(admin2);
        seatToken2.grantRole(seatToken2.MINTER_ROLE(), address(tranche2));
        seatToken2.grantRole(seatToken2.BURNER_ROLE(), address(tranche2));
        principalManager2.grantRole(principalManager2.BONDING_ROLE(), address(tranche2));
        vm.stopPrank();

        // Move totalSupply up so we can test upperBound <= currentSupply.
        usdc2.mint(alice2, 100e6);
        vm.startPrank(alice2);
        usdc2.approve(address(tranche2), 100e6);
        tranche2.purchase(alice2, 5, 5e6);
        vm.stopPrank();

        // price == 0
        {
            uint256[] memory newUpperBounds = new uint256[](1);
            uint256[] memory newPrices = new uint256[](1);
            newUpperBounds[0] = 11;
            newPrices[0] = 0;
            vm.prank(admin2);
            vm.expectRevert(BondingTranche.InvalidTrancheConfiguration.selector);
            tranche2.extendTranches(newUpperBounds, newPrices);
        }

        // upperBound <= previousUpperBound
        {
            uint256[] memory newUpperBounds = new uint256[](1);
            uint256[] memory newPrices = new uint256[](1);
            newUpperBounds[0] = 10;
            newPrices[0] = 2e6;
            vm.prank(admin2);
            vm.expectRevert(BondingTranche.InvalidTrancheConfiguration.selector);
            tranche2.extendTranches(newUpperBounds, newPrices);
        }

        // upperBound <= currentSupply
        {
            uint256[] memory newUpperBounds = new uint256[](1);
            uint256[] memory newPrices = new uint256[](1);
            newUpperBounds[0] = 5; // currentSupply is 5
            newPrices[0] = 2e6;
            vm.prank(admin2);
            vm.expectRevert(BondingTranche.InvalidTrancheConfiguration.selector);
            tranche2.extendTranches(newUpperBounds, newPrices);
        }

        // upperBound > seatToken.supplyCap()
        {
            uint256[] memory newUpperBounds = new uint256[](1);
            uint256[] memory newPrices = new uint256[](1);
            newUpperBounds[0] = 101;
            newPrices[0] = 2e6;
            vm.prank(admin2);
            vm.expectRevert(BondingTranche.InvalidTrancheConfiguration.selector);
            tranche2.extendTranches(newUpperBounds, newPrices);
        }
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

    // ── Pause cascade: BondingTranche reads PrincipalManager.paused() ──────────

    function test_PurchaseRevertsWhilePrincipalManagerPaused() public {
        usdc.mint(alice, 5e6);
        vm.prank(alice);
        usdc.approve(address(bondingTranche), 5e6);

        vm.prank(admin);
        principalManager.pause();

        vm.prank(alice);
        vm.expectRevert(BondingTranche.PrincipalManagerPaused.selector);
        bondingTranche.purchase(alice, 1, 1e6);
    }

    function test_RefundRevertsWhilePrincipalManagerPaused() public {
        usdc.mint(alice, 5e6);
        vm.startPrank(alice);
        usdc.approve(address(bondingTranche), 5e6);
        bondingTranche.purchase(alice, 1, 1e6);
        vm.stopPrank();

        vm.prank(admin);
        principalManager.pause();

        vm.prank(alice);
        vm.expectRevert(BondingTranche.PrincipalManagerPaused.selector);
        bondingTranche.refund(1, alice);
    }

    function test_ReclaimRevertsWhilePrincipalManagerPaused() public {
        usdc.mint(alice, 5e6);
        vm.startPrank(alice);
        usdc.approve(address(bondingTranche), 5e6);
        bondingTranche.purchase(alice, 1, 1e6);
        vm.stopPrank();

        // Advance past inactivity period so reclaim would otherwise be valid.
        vm.warp(block.timestamp + 366 days);
        assertTrue(seatToken.isInactive(alice));

        vm.prank(admin);
        principalManager.pause();

        vm.prank(reclaimer);
        vm.expectRevert(BondingTranche.PrincipalManagerPaused.selector);
        bondingTranche.reclaim(alice);
    }

    function test_PurchaseResumes_afterUnpause() public {
        usdc.mint(alice, 5e6);
        vm.prank(alice);
        usdc.approve(address(bondingTranche), 5e6);

        vm.prank(admin);
        principalManager.pause();
        vm.prank(admin);
        principalManager.unpause();

        vm.prank(alice);
        bondingTranche.purchase(alice, 1, 1e6);
        assertEq(seatToken.balanceOf(alice), 1);
    }
}
