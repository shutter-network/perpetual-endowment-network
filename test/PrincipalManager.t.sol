// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {PrincipalManager} from "../src/PrincipalManager.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PrincipalManagerTest is Test {
    MockUSDC internal usdc;
    PrincipalManager internal principalManager;
    ERC4626Mock internal principalVault;
    ERC4626Mock internal yieldVault;

    address internal admin = makeAddr("admin");
    address internal bonding = makeAddr("bonding");
    address internal refundReceiver = makeAddr("refundReceiver");

    function setUp() public {
        usdc = new MockUSDC();
        principalManager = new PrincipalManager(usdc, admin, bonding, 10e6, IERC4626(address(0)), IERC4626(address(0)), address(0));
        principalVault = new ERC4626Mock(address(usdc));
        yieldVault = new ERC4626Mock(address(usdc));
    }

    function test_DirectFundingIncreasesManagedAssets() public {
        usdc.mint(address(principalManager), 12e6);

        assertEq(principalManager.liquidAssets(), 12e6);
        assertEq(principalManager.totalManagedAssets(), 12e6);
    }

    function test_PayRefundUsesLiquidAssets() public {
        usdc.mint(address(principalManager), 15e6);

        vm.prank(bonding);
        principalManager.recordPurchase(15e6);

        vm.prank(bonding);
        principalManager.payRefund(refundReceiver, 4e6);

        assertEq(usdc.balanceOf(refundReceiver), 4e6);
        assertEq(principalManager.liquidAssets(), 11e6);
    }

    function test_CanDepositExcessAndAutoWithdrawForRefund() public {
        usdc.mint(address(principalManager), 100e6);

        vm.prank(bonding);
        principalManager.recordPurchase(100e6);

        vm.prank(admin);
        principalManager.setPrincipalVault(principalVault);

        vm.prank(admin);
        uint256 shares = principalManager.depositExcessToPrincipalVault();

        assertEq(shares, 90e6);
        assertEq(principalManager.liquidAssets(), 10e6);
        assertEq(principalManager.deployedAssets(), 90e6);

        vm.prank(bonding);
        principalManager.payRefund(refundReceiver, 50e6);

        assertEq(usdc.balanceOf(refundReceiver), 50e6);
        assertEq(principalManager.liquidAssets(), 0);
        assertEq(principalManager.deployedAssets(), 50e6);
        assertEq(principalManager.totalManagedAssets(), 50e6);
        assertEq(principalManager.accountedPrincipal(), 50e6);
    }

    function test_DepositToVaultRespectsReserveTarget() public {
        usdc.mint(address(principalManager), 25e6);

        vm.prank(bonding);
        principalManager.recordPurchase(25e6);

        vm.prank(admin);
        principalManager.setPrincipalVault(principalVault);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PrincipalManager.InsufficientLiquidity.selector, 16e6, 15e6));
        principalManager.depositToPrincipalVault(16e6);

        vm.prank(admin);
        principalManager.depositToPrincipalVault(15e6);

        assertEq(principalManager.liquidAssets(), 10e6);
        assertEq(principalManager.deployedAssets(), 15e6);
    }

    function test_CannotSwitchVaultWithOpenPosition() public {
        ERC4626Mock secondPrincipalVault = new ERC4626Mock(address(usdc));
        usdc.mint(address(principalManager), 25e6);

        vm.prank(bonding);
        principalManager.recordPurchase(25e6);

        vm.prank(admin);
        principalManager.setPrincipalVault(principalVault);

        vm.prank(admin);
        principalManager.depositToPrincipalVault(15e6);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(PrincipalManager.ActiveVaultPositionExists.selector, address(principalVault), 15e6)
        );
        principalManager.setPrincipalVault(secondPrincipalVault);
    }

    function test_SetPrincipalVaultRejectsWrongAsset() public {
        MockUSDC otherAsset = new MockUSDC();
        ERC4626Mock wrongPrincipalVault = new ERC4626Mock(address(otherAsset));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrincipalManager.InvalidPrincipalVaultAsset.selector, address(wrongPrincipalVault), address(usdc)
            )
        );
        principalManager.setPrincipalVault(wrongPrincipalVault);
    }

    function test_RecordPurchaseIncreasesAccountedPrincipal() public {
        usdc.mint(address(principalManager), 12e6);

        vm.prank(bonding);
        principalManager.recordPurchase(12e6);

        assertEq(principalManager.accountedPrincipal(), 12e6);
        assertEq(principalManager.availableYield(), 0);
    }

    function test_CanTransferOnlyYieldToYieldVault() public {
        usdc.mint(address(principalManager), 100e6);

        vm.prank(bonding);
        principalManager.recordPurchase(100e6);

        vm.startPrank(admin);
        principalManager.setPrincipalVault(principalVault);
        principalManager.setYieldVault(yieldVault, admin);
        vm.stopPrank();

        vm.prank(admin);
        principalManager.depositExcessToPrincipalVault();

        usdc.mint(address(principalVault), 15e6);

        assertEq(principalManager.availableYield(), 14_999_999);

        vm.prank(admin);
        principalManager.transferYieldToVault(12e6);

        assertEq(usdc.balanceOf(address(yieldVault)), 12e6);
        assertEq(yieldVault.balanceOf(admin), 12e6);
        assertEq(principalManager.accountedPrincipal(), 100e6);
        assertEq(principalManager.availableYield(), 2_999_999);
        assertEq(principalManager.totalManagedAssets(), 102_999_999);
    }

    function test_CannotTransferMoreThanAvailableYield() public {
        usdc.mint(address(principalManager), 50e6);

        vm.prank(bonding);
        principalManager.recordPurchase(50e6);

        vm.startPrank(admin);
        principalManager.setPrincipalVault(principalVault);
        principalManager.setYieldVault(yieldVault, admin);
        vm.stopPrank();

        vm.prank(admin);
        principalManager.depositExcessToPrincipalVault();

        usdc.mint(address(principalVault), 5e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PrincipalManager.InsufficientAvailableYield.selector, 6e6, 4_999_999));
        principalManager.transferYieldToVault(6e6);
    }
}
