// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract FrontRunningIntegrationTest is Test {
    uint256 internal constant REFUND_PRICE = 0.5e6;
    uint256 internal constant TRANCHE_ONE_PRICE = 1e6;
    uint256 internal constant TRANCHE_TWO_PRICE = 1.25e6;

    address internal admin = makeAddr("admin");
    address internal seedBuyer = makeAddr("seedBuyer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockUSDC internal usdc;
    SeatToken internal seatToken;
    PrincipalManager internal principalManager;
    BondingTranche internal bondingTranche;

    function setUp() public {
        usdc = new MockUSDC();
        seatToken = new SeatToken("PEN Seat", "SEAT", 10_000, 365 days, admin, address(0), address(0), address(0));
        principalManager = new PrincipalManager(usdc, admin, address(0), 0, IERC4626(address(0)));

        uint256[] memory upperBounds = new uint256[](2);
        uint256[] memory prices = new uint256[](2);
        upperBounds[0] = 2_000;
        upperBounds[1] = 10_000;
        prices[0] = TRANCHE_ONE_PRICE;
        prices[1] = TRANCHE_TWO_PRICE;

        bondingTranche =
            new BondingTranche(seatToken, principalManager, REFUND_PRICE, admin, address(0), upperBounds, prices);

        vm.startPrank(admin);
        seatToken.grantRole(seatToken.MINTER_ROLE(), address(bondingTranche));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));
        principalManager.grantRole(principalManager.BONDING_ROLE(), address(bondingTranche));
        vm.stopPrank();
    }

    function test_FrontRunningAcrossTranchesRevertsBuyerWhenActualCostExceedsMaxCost() public {
        _purchase(seedBuyer, 1_900, 1_900 * TRANCHE_ONE_PRICE);

        assertEq(seatToken.totalSupply(), 1_900);
        assertEq(bondingTranche.currentSeatPrice(), TRANCHE_ONE_PRICE);

        uint256 bobQuotedCost = bondingTranche.quotePurchase(100);
        assertEq(bobQuotedCost, 100 * TRANCHE_ONE_PRICE);
        usdc.mint(bob, 200e6);

        vm.prank(bob);
        usdc.approve(address(bondingTranche), 200e6);

        _purchase(alice, 5_000, 6_225e6);

        assertEq(seatToken.totalSupply(), 6_900);
        assertEq(bondingTranche.currentSeatPrice(), TRANCHE_TWO_PRICE);

        uint256 bobActualCost = bondingTranche.quotePurchase(100);
        assertEq(bobActualCost, 100 * TRANCHE_TWO_PRICE);
        assertGt(bobActualCost, bobQuotedCost);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BondingTranche.PurchaseCostExceedsLimit.selector, bobActualCost, bobQuotedCost)
        );
        bondingTranche.purchase(bob, 100, bobQuotedCost);

        assertEq(seatToken.balanceOf(bob), 0);
        assertEq(seatToken.totalSupply(), 6_900);
        assertEq(usdc.balanceOf(bob), 200e6);
        assertEq(principalManager.accountedPrincipal(), 8_125e6);
    }

    function _purchase(address buyer_, uint256 seats_, uint256 maxCost_) internal {
        uint256 quotedCost = bondingTranche.quotePurchase(seats_);
        usdc.mint(buyer_, quotedCost);

        vm.startPrank(buyer_);
        usdc.approve(address(bondingTranche), quotedCost);
        bondingTranche.purchase(buyer_, seats_, maxCost_);
        vm.stopPrank();
    }
}
