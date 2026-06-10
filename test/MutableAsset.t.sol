// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {PrincipalManager} from "../src/PrincipalManager.sol";
import {BondingTranche} from "../src/BondingTranche.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockDAI} from "./mocks/MockDAI.sol";

contract PrincipalManagerMigrationTest is Test {
    MockUSDC internal usdc;
    MockUSDT internal usdt;
    MockDAI internal dai;
    PrincipalManager internal pm;
    ERC4626Mock internal vault;

    address internal admin = makeAddr("admin");
    address internal bonding = makeAddr("bonding");

    function setUp() public {
        usdc = new MockUSDC();
        usdt = new MockUSDT();
        dai = new MockDAI();
        pm = new PrincipalManager(IERC20(address(usdc)), admin, bonding, 0, IERC4626(address(0)));
        vault = new ERC4626Mock(address(usdc));
    }

    function test_beginMigration_revertsOnSameAsset() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PrincipalManager.InvalidAsset.selector, address(usdc)));
        pm.beginAssetMigration(IERC20(address(usdc)));
    }

    function test_beginMigration_revertsOnDifferentDecimals() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PrincipalManager.AssetDecimalsMismatch.selector, uint8(6), uint8(18)));
        pm.beginAssetMigration(IERC20(address(dai)));
    }

    function test_beginMigration_revertsIfAlreadyActive() public {
        vm.startPrank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));
        vm.expectRevert(PrincipalManager.MigrationAlreadyActive.selector);
        pm.beginAssetMigration(IERC20(address(usdt)));
        vm.stopPrank();
    }

    function test_beginMigration_detachesPrincipalVaultIntoPreviousList() public {
        vm.prank(admin);
        pm.setPrincipalVault(IERC4626(address(vault)));

        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        assertEq(address(pm.principalVault()), address(0));
        assertEq(pm.previousPrincipalVaultCount(), 1);
        assertEq(address(pm.previousPrincipalVaults(0)), address(vault));
    }

    function test_beginMigration_freezesPrincipalVaultOps() public {
        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        vm.startPrank(admin);
        vm.expectRevert(PrincipalManager.MigrationActive.selector);
        pm.setPrincipalVault(IERC4626(address(vault)));

        vm.expectRevert(PrincipalManager.MigrationActive.selector);
        pm.depositToPrincipalVault(1);

        vm.expectRevert(PrincipalManager.MigrationActive.selector);
        pm.depositExcessToPrincipalVault();

        vm.expectRevert(PrincipalManager.MigrationActive.selector);
        pm.withdrawFromPrincipalVault(1, admin);
        vm.stopPrank();
    }

    function test_beginMigration_freezesRecordPurchaseAndPayRefund() public {
        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        vm.prank(bonding);
        vm.expectRevert(PrincipalManager.MigrationActive.selector);
        pm.recordPurchase(1);

        vm.prank(bonding);
        vm.expectRevert(PrincipalManager.MigrationActive.selector);
        pm.payRefund(admin, 1);
    }

    function test_migrationWithdraw_revertsWhenNotActive() public {
        vm.prank(admin);
        vm.expectRevert(PrincipalManager.MigrationNotActive.selector);
        pm.migrationWithdraw(admin, 1);
    }

    function test_migrationWithdraw_transfersOldAsset() public {
        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        usdc.mint(address(pm), 50e6);

        vm.prank(admin);
        pm.migrationWithdraw(admin, 30e6);

        assertEq(usdc.balanceOf(admin), 30e6);
        assertEq(usdc.balanceOf(address(pm)), 20e6);
    }

    function test_completeMigration_revertsIfNotActive() public {
        vm.prank(admin);
        vm.expectRevert(PrincipalManager.MigrationNotActive.selector);
        pm.completeAssetMigration();
    }

    function test_completeMigration_revertsIfOldAssetNotDrained() public {
        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        usdc.mint(address(pm), 1e6);

        vm.prank(admin);
        vm.expectRevert(PrincipalManager.MigrationStateNotClean.selector);
        pm.completeAssetMigration();
    }

    function test_completeMigration_revertsIfPreviousVaultStillHoldsShares() public {
        vm.prank(admin);
        pm.setPrincipalVault(IERC4626(address(vault)));

        usdc.mint(address(pm), 100e6);

        vm.prank(bonding);
        pm.recordPurchase(100e6);

        vm.prank(admin);
        pm.depositExcessToPrincipalVault();

        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        usdt.mint(address(pm), 100e6);

        vm.prank(admin);
        vm.expectRevert(PrincipalManager.MigrationStateNotClean.selector);
        pm.completeAssetMigration();
    }

    function test_completeMigration_revertsIfUnderfunded() public {
        usdc.mint(address(pm), 100e6);
        vm.prank(bonding);
        pm.recordPurchase(100e6);

        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        vm.prank(admin);
        pm.migrationWithdraw(admin, 100e6);

        usdt.mint(address(pm), 99e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PrincipalManager.MigrationUnderfunded.selector, 100e6, 99e6));
        pm.completeAssetMigration();
    }

    function test_completeMigration_swapsAssetAndUnfreezes() public {
        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        usdt.mint(address(pm), 100e6);

        vm.prank(admin);
        pm.completeAssetMigration();

        assertEq(address(pm.asset()), address(usdt));
        assertFalse(pm.migrationActive());
        assertEq(address(pm.pendingAsset()), address(0));

        usdt.mint(address(pm), 50e6);
        vm.prank(bonding);
        pm.recordPurchase(50e6);

        vm.prank(bonding);
        pm.payRefund(admin, 10e6);
        assertEq(usdt.balanceOf(admin), 10e6);
    }

    function test_completeMigration_clearsPreviousVaultBookkeeping() public {
        vm.prank(admin);
        pm.setPrincipalVault(IERC4626(address(vault)));

        usdc.mint(address(pm), 100e6);

        vm.prank(bonding);
        pm.recordPurchase(100e6);

        vm.prank(admin);
        pm.depositExcessToPrincipalVault();

        vm.startPrank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        uint256 withdrawable = vault.maxWithdraw(address(pm));
        pm.withdrawFromVault(IERC4626(address(vault)), withdrawable, admin);

        uint256 liquid = pm.liquidAssets();
        if (liquid > 0) pm.migrationWithdraw(admin, liquid);

        usdt.mint(address(pm), 100e6);

        pm.completeAssetMigration();
        vm.stopPrank();

        assertEq(pm.previousPrincipalVaultCount(), 0);
    }

    function test_cancelMigration_revertsIfNotActive() public {
        vm.prank(admin);
        vm.expectRevert(PrincipalManager.MigrationNotActive.selector);
        pm.cancelAssetMigration();
    }

    function test_cancelMigration_unfreezesWithOriginalAsset() public {
        vm.prank(admin);
        pm.beginAssetMigration(IERC20(address(usdt)));

        vm.prank(admin);
        pm.cancelAssetMigration();

        assertFalse(pm.migrationActive());
        assertEq(address(pm.asset()), address(usdc));
        assertEq(address(pm.pendingAsset()), address(0));

        usdc.mint(address(pm), 50e6);
        vm.prank(bonding);
        pm.recordPurchase(50e6);
    }
}

contract BondingTrancheMigrationTest is Test {
    MockUSDC internal usdc;
    MockUSDT internal usdt;
    SeatToken internal st;
    PrincipalManager internal pm;
    BondingTranche internal bt;

    address internal buyer = makeAddr("buyer");

    function setUp() public {
        usdc = new MockUSDC();
        usdt = new MockUSDT();

        st = new SeatToken("Seat", "SEAT", 1_000_000, uint48(365 days), address(this), address(0), address(0), address(0));

        uint256[] memory upperBounds = new uint256[](2);
        uint256[] memory prices = new uint256[](2);
        upperBounds[0] = 500_000;
        upperBounds[1] = 1_000_000;
        prices[0] = 1e6;
        prices[1] = 2e6;

        pm = new PrincipalManager(IERC20(address(usdc)), address(this), address(0), 0, IERC4626(address(0)));

        bt = new BondingTranche(st, pm, 0.5e6, address(this), address(0), upperBounds, prices);

        st.grantRole(st.MINTER_ROLE(), address(bt));
        st.grantRole(st.BURNER_ROLE(), address(bt));
        pm.grantRole(pm.BONDING_ROLE(), address(bt));

        usdc.mint(buyer, 1000e6);
        vm.prank(buyer);
        usdc.approve(address(bt), type(uint256).max);
    }

    function test_purchase_revertsWhenMigrationActive() public {
        pm.beginAssetMigration(IERC20(address(usdt)));

        vm.prank(buyer);
        vm.expectRevert(BondingTranche.MigrationActiveOnPrincipalManager.selector);
        bt.purchase(buyer, 1, type(uint256).max);
    }

    function test_refund_revertsWhenMigrationActive() public {
        vm.prank(buyer);
        bt.purchase(buyer, 1, type(uint256).max);

        pm.beginAssetMigration(IERC20(address(usdt)));

        vm.prank(buyer);
        vm.expectRevert(BondingTranche.MigrationActiveOnPrincipalManager.selector);
        bt.refund(1, buyer);
    }

    function test_syncFromPrincipalManager_updatesAsset() public {
        pm.beginAssetMigration(IERC20(address(usdt)));

        uint256 liquid = pm.liquidAssets();
        if (liquid > 0) pm.migrationWithdraw(address(this), liquid);

        usdt.mint(address(pm), 100e6);
        pm.completeAssetMigration();

        bt.syncFromPrincipalManager();
        assertEq(address(bt.asset()), address(usdt));
    }

    function test_setRefundPrice_updatesPrice() public {
        bt.setRefundPrice(2e6);
        assertEq(bt.refundPrice(), 2e6);
    }

    function test_setRefundPrice_revertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(BondingTranche.InvalidPrice.selector, 0));
        bt.setRefundPrice(0);
    }

    function test_replaceTrancheSchedule_replacesSchedule() public {
        uint256[] memory newBounds = new uint256[](2);
        uint256[] memory newPrices = new uint256[](2);
        newBounds[0] = 100;
        newBounds[1] = 500;
        newPrices[0] = 3e6;
        newPrices[1] = 5e6;

        bt.replaceTrancheSchedule(newBounds, newPrices);

        assertEq(bt.trancheCount(), 2);
        (uint256 ub, uint256 p) = bt.tranche(0);
        assertEq(ub, 100);
        assertEq(p, 3e6);
    }

    function test_replaceTrancheSchedule_revertsBelowCurrentSupply() public {
        vm.prank(buyer);
        bt.purchase(buyer, 5, type(uint256).max);

        uint256[] memory newBounds = new uint256[](1);
        uint256[] memory newPrices = new uint256[](1);
        newBounds[0] = 3;
        newPrices[0] = 1e6;

        vm.expectRevert(abi.encodeWithSelector(BondingTranche.TrancheScheduleBelowSupply.selector, 5, 5));
        bt.replaceTrancheSchedule(newBounds, newPrices);
    }

    function test_replaceTrancheSchedule_revertsAboveSupplyCap() public {
        uint256[] memory newBounds = new uint256[](1);
        uint256[] memory newPrices = new uint256[](1);
        newBounds[0] = 1_000_001;
        newPrices[0] = 1e6;

        vm.expectRevert(BondingTranche.InvalidTrancheConfiguration.selector);
        bt.replaceTrancheSchedule(newBounds, newPrices);
    }
}
