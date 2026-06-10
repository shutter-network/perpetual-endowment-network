// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {PrincipalManager} from "../../src/PrincipalManager.sol";
import {BondingTranche} from "../../src/BondingTranche.sol";
import {SeatToken} from "../../src/SeatToken.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockUSDT} from "../mocks/MockUSDT.sol";

contract AssetMigrationTest is Test {
    MockUSDC internal usdc;
    MockUSDT internal usdt;
    SeatToken internal st;
    PrincipalManager internal pm;
    BondingTranche internal bt;
    ERC4626Mock internal vault;

    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");

    function setUp() public {
        usdc = new MockUSDC();
        usdt = new MockUSDT();

        st = new SeatToken("Seat", "SEAT", 1_000_000, uint48(365 days), address(this), address(0), address(0), address(0));

        uint256[] memory upperBounds = new uint256[](2);
        uint256[] memory prices = new uint256[](2);
        upperBounds[0] = 500_000;
        upperBounds[1] = 1_000_000;
        prices[0] = 10e6;
        prices[1] = 20e6;

        pm = new PrincipalManager(IERC20(address(usdc)), address(this), address(0), 0, IERC4626(address(0)));

        bt = new BondingTranche(st, pm, 10e6, address(this), address(0), upperBounds, prices);

        st.grantRole(st.MINTER_ROLE(), address(bt));
        st.grantRole(st.BURNER_ROLE(), address(bt));
        pm.grantRole(pm.BONDING_ROLE(), address(bt));

        vault = new ERC4626Mock(address(usdc));
        pm.setPrincipalVault(IERC4626(address(vault)));

        usdc.mint(buyer, 1000e6);
        vm.startPrank(buyer);
        usdc.approve(address(bt), type(uint256).max);
        bt.purchase(buyer, 5, type(uint256).max);
        vm.stopPrank();

        pm.depositExcessToPrincipalVault();
    }

    function test_endToEnd_USDC_to_USDT_simulatedSwap_atPar() public {
        uint256 accountedPrincipal = pm.accountedPrincipal();

        pm.beginAssetMigration(IERC20(address(usdt)));

        uint256 vaultBalance = vault.maxWithdraw(address(pm));
        if (vaultBalance > 0) {
            pm.withdrawFromVault(IERC4626(address(vault)), vaultBalance, address(this));
        }

        uint256 liquidBal = pm.liquidAssets();
        if (liquidBal > 0) {
            pm.migrationWithdraw(address(this), liquidBal);
        }

        usdt.mint(address(pm), accountedPrincipal);

        pm.completeAssetMigration();

        bt.syncFromPrincipalManager();
        bt.setRefundPrice(10e6);

        uint256[] memory newBounds = new uint256[](2);
        uint256[] memory newPrices = new uint256[](2);
        newBounds[0] = 500_000;
        newBounds[1] = 1_000_000;
        newPrices[0] = 10e6;
        newPrices[1] = 20e6;
        bt.replaceTrancheSchedule(newBounds, newPrices);

        assertEq(address(pm.asset()), address(usdt));
        assertEq(address(bt.asset()), address(usdt));

        usdt.mint(buyer2, 100e6);
        vm.startPrank(buyer2);
        usdt.approve(address(bt), type(uint256).max);
        bt.purchase(buyer2, 1, type(uint256).max);
        vm.stopPrank();

        assertGt(IERC20(address(st)).balanceOf(buyer2), 0);

        uint256 buyerBalanceBefore = usdt.balanceOf(buyer);
        vm.prank(buyer);
        bt.refund(1, buyer);
        assertGt(usdt.balanceOf(buyer), buyerBalanceBefore);
    }

    function test_endToEnd_underfundedSwap_revertsAtVote2() public {
        uint256 accountedPrincipal = pm.accountedPrincipal();

        pm.beginAssetMigration(IERC20(address(usdt)));

        uint256 vaultBalance = vault.maxWithdraw(address(pm));
        if (vaultBalance > 0) {
            pm.withdrawFromVault(IERC4626(address(vault)), vaultBalance, address(this));
        }

        uint256 liquidBal = pm.liquidAssets();
        if (liquidBal > 0) {
            pm.migrationWithdraw(address(this), liquidBal);
        }

        usdt.mint(address(pm), accountedPrincipal - 1e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                PrincipalManager.MigrationUnderfunded.selector, accountedPrincipal, accountedPrincipal - 1e6
            )
        );
        pm.completeAssetMigration();

        usdt.mint(address(pm), 1e6);
        pm.completeAssetMigration();

        assertEq(address(pm.asset()), address(usdt));
        assertFalse(pm.migrationActive());
    }

    function test_endToEnd_cancelAfterPartialDrain() public {
        pm.beginAssetMigration(IERC20(address(usdt)));

        uint256 vaultBalance = vault.maxWithdraw(address(pm));
        if (vaultBalance > 0) {
            pm.withdrawFromVault(IERC4626(address(vault)), vaultBalance, address(this));
        }

        pm.cancelAssetMigration();

        assertFalse(pm.migrationActive());
        assertEq(address(pm.asset()), address(usdc));

        usdc.mint(address(pm), vaultBalance);

        usdc.mint(buyer2, 100e6);
        vm.startPrank(buyer2);
        usdc.approve(address(bt), type(uint256).max);
        bt.purchase(buyer2, 1, type(uint256).max);
        vm.stopPrank();

        assertGt(IERC20(address(st)).balanceOf(buyer2), 0);
    }
}
