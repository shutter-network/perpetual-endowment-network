// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PrincipalUnderflowIntegrationTest is Test {
    uint256 internal constant SEAT_COUNT = 1_000;
    uint256 internal constant PURCHASE_PRICE_PER_SEAT = 5e6;
    uint256 internal constant REFUND_PRICE_PER_SEAT = 0.5e6;
    uint256 internal constant ACCOUNTED_PRINCIPAL = SEAT_COUNT * PURCHASE_PRICE_PER_SEAT; // 5_000e6
    uint256 internal constant REFUND_OBLIGATION = SEAT_COUNT * REFUND_PRICE_PER_SEAT; // 500e6
    // Loss large enough to push managedAssets below the refund obligation.
    uint256 internal constant VAULT_LOSS = 4_600e6;
    uint256 internal constant EXPECTED_REFUND = SEAT_COUNT * REFUND_PRICE_PER_SEAT; // 500e6

    address internal admin = makeAddr("admin");
    address internal member = makeAddr("member");
    address internal sink = makeAddr("sink");

    MockUSDC internal usdc;
    SeatToken internal seatToken;
    PrincipalManager internal principalManager;
    BondingTranche internal bondingTranche;
    ERC4626Mock internal principalVault;

    function setUp() public {
        usdc = new MockUSDC();
        seatToken = new SeatToken("PEN Seat", "SEAT", SEAT_COUNT, 365 days, admin, address(0), address(0), address(0));
        principalManager = new PrincipalManager(usdc, admin, address(0), 0, IERC4626(address(0)));
        principalVault = new ERC4626Mock(address(usdc));

        uint256[] memory upperBounds = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        upperBounds[0] = SEAT_COUNT;
        prices[0] = PURCHASE_PRICE_PER_SEAT;

        bondingTranche = new BondingTranche(
            seatToken, principalManager, REFUND_PRICE_PER_SEAT, admin, address(0), upperBounds, prices
        );

        vm.startPrank(admin);
        seatToken.grantRole(seatToken.MINTER_ROLE(), address(bondingTranche));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));
        principalManager.grantRole(principalManager.BONDING_ROLE(), address(bondingTranche));
        principalManager.setPrincipalVault(principalVault);
        vm.stopPrank();

        usdc.mint(member, ACCOUNTED_PRINCIPAL);

        vm.startPrank(member);
        usdc.approve(address(bondingTranche), ACCOUNTED_PRINCIPAL);
        bondingTranche.purchase(member, SEAT_COUNT, ACCOUNTED_PRINCIPAL);
        vm.stopPrank();
    }

    function test_RefundRevertsWhenVaultLossPushesManagedAssetsBelowRefundObligation() public {
        assertEq(principalManager.accountedPrincipal(), ACCOUNTED_PRINCIPAL);
        assertEq(principalManager.totalManagedAssets(), ACCOUNTED_PRINCIPAL);
        assertEq(principalManager.deployedAssets(), ACCOUNTED_PRINCIPAL);

        vm.prank(address(principalVault));
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(sink, VAULT_LOSS);

        assertEq(principalManager.totalManagedAssets(), ACCOUNTED_PRINCIPAL - VAULT_LOSS);
        assertEq(principalManager.deployedAssets(), ACCOUNTED_PRINCIPAL - VAULT_LOSS);

        vm.prank(member);
        vm.expectRevert(
            abi.encodeWithSelector(
                BondingTranche.RefundObligationExceedsManagedAssets.selector,
                REFUND_OBLIGATION,
                ACCOUNTED_PRINCIPAL - VAULT_LOSS
            )
        );
        bondingTranche.refund(SEAT_COUNT, member);

        assertEq(seatToken.balanceOf(member), SEAT_COUNT);
        assertEq(seatToken.totalSupply(), SEAT_COUNT);
        assertEq(usdc.balanceOf(member), 0);
        assertEq(usdc.balanceOf(sink), VAULT_LOSS);
        assertEq(principalManager.accountedPrincipal(), ACCOUNTED_PRINCIPAL);
        assertEq(principalManager.totalManagedAssets(), ACCOUNTED_PRINCIPAL - VAULT_LOSS);
        assertEq(bondingTranche.quoteRefund(SEAT_COUNT), EXPECTED_REFUND);
    }
}
