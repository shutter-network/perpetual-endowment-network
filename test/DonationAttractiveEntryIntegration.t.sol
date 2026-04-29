// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract DonationAttractiveEntryIntegrationTest is Test {
    uint256 internal constant SOLD_SEATS = 10_000;
    uint256 internal constant SUPPLY_CAP = 20_000;
    uint256 internal constant SEAT_PRICE = 1e6;
    uint256 internal constant DONATION = 10_000e6;

    address internal admin = makeAddr("admin");
    address internal seedBuyer = makeAddr("seedBuyer");
    address internal donor = makeAddr("donor");

    MockUSDC internal usdc;
    SeatToken internal seatToken;
    PrincipalManager internal principalManager;
    BondingTranche internal bondingTranche;

    function setUp() public {
        usdc = new MockUSDC();
        seatToken = new SeatToken("PEN Seat", "SEAT", SUPPLY_CAP, 365 days, admin, address(0), address(0), address(0));
        principalManager = new PrincipalManager(usdc, admin, address(0), 0, IERC4626(address(0)));

        uint256[] memory upperBounds = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        upperBounds[0] = SUPPLY_CAP;
        prices[0] = SEAT_PRICE;

        bondingTranche = new BondingTranche(seatToken, principalManager, 0.5e6, admin, address(0), upperBounds, prices);

        vm.startPrank(admin);
        seatToken.grantRole(seatToken.MINTER_ROLE(), address(bondingTranche));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));
        principalManager.grantRole(principalManager.BONDING_ROLE(), address(bondingTranche));
        vm.stopPrank();
    }

    function test_DonationImprovesGovernancePriceRatioWithoutChangingSeatPrice() public {
        uint256 initialPurchaseCost = SOLD_SEATS * SEAT_PRICE;
        usdc.mint(seedBuyer, initialPurchaseCost);

        vm.startPrank(seedBuyer);
        usdc.approve(address(bondingTranche), initialPurchaseCost);
        bondingTranche.purchase(seedBuyer, SOLD_SEATS, initialPurchaseCost);
        vm.stopPrank();

        assertEq(seatToken.totalSupply(), SOLD_SEATS);
        assertEq(principalManager.accountedPrincipal(), 10_000e6);
        assertEq(principalManager.totalManagedAssets(), 10_000e6);
        assertEq(bondingTranche.quotePurchase(1), SEAT_PRICE);

        usdc.mint(donor, DONATION);
        vm.prank(donor);
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(principalManager), DONATION);

        assertEq(bondingTranche.quotePurchase(1), SEAT_PRICE);
        assertEq(principalManager.accountedPrincipal(), 10_000e6);
        assertEq(principalManager.totalManagedAssets(), 20_000e6);
        assertEq(principalManager.availableYield(), DONATION);

        uint256 governancePriceRatio = principalManager.totalManagedAssets() / seatToken.totalSupply();
        assertEq(governancePriceRatio, 2e6);
    }
}
