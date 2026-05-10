// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC4626Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC4626Mock.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract LimitedWithdrawalVault is ERC4626Mock {
    uint256 public withdrawalLimit = type(uint256).max;

    constructor(address underlying) ERC4626Mock(underlying) {}

    function setWithdrawalLimit(uint256 newLimit) external {
        withdrawalLimit = newLimit;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 allowed = super.maxWithdraw(owner);
        if (allowed < withdrawalLimit) {
            return allowed;
        }

        return withdrawalLimit;
    }
}

contract BankRunIntegrationTest is Test {
    uint256 internal constant PURCHASE_PRICE = 10e6;
    uint256 internal constant REFUND_PRICE = 5e6;
    uint256 internal constant RESERVE_TARGET = 10e6;
    uint256 internal constant TOTAL_PURCHASES = 10;

    address internal admin = makeAddr("admin");
    address internal reclaimer = makeAddr("reclaimer");
    address[10] internal holders;

    function setUp() public {
        holders[0] = makeAddr("alice");
        holders[1] = makeAddr("bob");
        holders[2] = makeAddr("carol");
        holders[3] = makeAddr("dave");
        holders[4] = makeAddr("erin");
        holders[5] = makeAddr("frank");
        holders[6] = makeAddr("grace");
        holders[7] = makeAddr("heidi");
        holders[8] = makeAddr("ivan");
        holders[9] = makeAddr("judy");
    }

    function test_BankRunWithdrawsFromPrincipalVaultWhenReserveIsExceeded() public {
        (
            MockUSDC usdc,
            SeatToken seatToken,
            PrincipalManager principalManager,
            BondingTranche bondingTranche,
            ERC4626Mock principalVault
        ) = _deployBankRunSystem();

        assertEq(principalManager.liquidAssets(), RESERVE_TARGET);
        assertEq(principalManager.deployedAssets(), 90e6);
        assertEq(principalManager.accountedPrincipal(), 100e6);
        assertEq(principalManager.totalManagedAssets(), 100e6);

        for (uint256 i; i < 4; ++i) {
            vm.prank(holders[i]);
            bondingTranche.refund(1, holders[i]);
        }

        assertEq(usdc.balanceOf(holders[0]), REFUND_PRICE);
        assertEq(usdc.balanceOf(holders[1]), REFUND_PRICE);
        assertEq(usdc.balanceOf(holders[2]), REFUND_PRICE);
        assertEq(usdc.balanceOf(holders[3]), REFUND_PRICE);

        assertEq(seatToken.totalSupply(), TOTAL_PURCHASES - 4);
        assertEq(principalManager.liquidAssets(), 0);
        assertEq(principalManager.deployedAssets(), 80e6);
        assertEq(principalManager.accountedPrincipal(), 80e6);
        assertEq(principalManager.totalManagedAssets(), 80e6);
        assertEq(principalVault.maxWithdraw(address(principalManager)), 80e6);
    }

    function test_BankRunRevertsGracefullyWhenPrincipalVaultIsIlliquid() public {
        (
            MockUSDC usdc,
            SeatToken seatToken,
            PrincipalManager principalManager,
            BondingTranche bondingTranche,
            LimitedWithdrawalVault principalVault
        ) = _deployBankRunSystemWithLimitedVault();

        vm.prank(holders[0]);
        bondingTranche.refund(1, holders[0]);

        vm.prank(holders[1]);
        bondingTranche.refund(1, holders[1]);

        principalVault.setWithdrawalLimit(4e6);

        vm.prank(holders[2]);
        vm.expectRevert(abi.encodeWithSelector(PrincipalManager.InsufficientLiquidity.selector, REFUND_PRICE, 4e6));
        bondingTranche.refund(1, holders[2]);

        assertEq(seatToken.balanceOf(holders[2]), 1);
        assertEq(usdc.balanceOf(holders[2]), 0);
        assertEq(seatToken.totalSupply(), TOTAL_PURCHASES - 2);
        assertEq(principalManager.liquidAssets(), 0);
        assertEq(principalManager.deployedAssets(), 90e6);
        assertEq(principalManager.accountedPrincipal(), 90e6);
    }

    function test_BankRunRevertsGracefullyWhenRefundObligationExceedsManagedAssets() public {
        MockUSDC usdc = new MockUSDC();
        SeatToken seatToken = new SeatToken("PEN Seat", "SEAT", 3, 365 days, admin, address(0), address(0), address(0));
        PrincipalManager principalManager = new PrincipalManager(usdc, admin, address(0), 0, IERC4626(address(0)));

        uint256[] memory upperBounds = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        upperBounds[0] = 3;
        prices[0] = 1e6;

        BondingTranche bondingTranche =
            new BondingTranche(seatToken, principalManager, 2e6, admin, reclaimer, upperBounds, prices);

        vm.startPrank(admin);
        seatToken.grantRole(seatToken.MINTER_ROLE(), address(bondingTranche));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));
        principalManager.grantRole(principalManager.BONDING_ROLE(), address(bondingTranche));
        vm.stopPrank();

        for (uint256 i; i < 3; ++i) {
            usdc.mint(holders[i], 1e6);

            vm.startPrank(holders[i]);
            usdc.approve(address(bondingTranche), 1e6);
            bondingTranche.purchase(holders[i], 1, 1e6);
            vm.stopPrank();
        }

        // With purchasePrice (1e6) < refundPrice (2e6), the system can never cover all seats:
        // obligation = 3 * 2e6 = 6e6, managedAssets = 3 * 1e6 = 3e6.
        // BondingTranche.refund must revert before any seat is burned.
        vm.prank(holders[0]);
        vm.expectRevert(abi.encodeWithSelector(BondingTranche.RefundObligationExceedsManagedAssets.selector, 6e6, 3e6));
        bondingTranche.refund(1, holders[0]);

        assertEq(seatToken.balanceOf(holders[0]), 1);
        assertEq(usdc.balanceOf(holders[0]), 0);
        assertEq(principalManager.accountedPrincipal(), 3e6);
        assertEq(principalManager.totalManagedAssets(), 3e6);
    }

    function _deployBankRunSystem()
        internal
        returns (
            MockUSDC usdc,
            SeatToken seatToken,
            PrincipalManager principalManager,
            BondingTranche bondingTranche,
            ERC4626Mock principalVault
        )
    {
        usdc = new MockUSDC();
        seatToken =
            new SeatToken("PEN Seat", "SEAT", TOTAL_PURCHASES, 365 days, admin, address(0), address(0), address(0));
        principalManager = new PrincipalManager(usdc, admin, address(0), RESERVE_TARGET, IERC4626(address(0)));
        principalVault = new ERC4626Mock(address(usdc));

        uint256[] memory upperBounds = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        upperBounds[0] = TOTAL_PURCHASES;
        prices[0] = PURCHASE_PRICE;

        bondingTranche =
            new BondingTranche(seatToken, principalManager, REFUND_PRICE, admin, reclaimer, upperBounds, prices);

        vm.startPrank(admin);
        seatToken.grantRole(seatToken.MINTER_ROLE(), address(bondingTranche));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));
        principalManager.grantRole(principalManager.BONDING_ROLE(), address(bondingTranche));
        principalManager.setPrincipalVault(principalVault);
        vm.stopPrank();

        for (uint256 i; i < TOTAL_PURCHASES; ++i) {
            usdc.mint(holders[i], PURCHASE_PRICE);

            vm.startPrank(holders[i]);
            usdc.approve(address(bondingTranche), PURCHASE_PRICE);
            bondingTranche.purchase(holders[i], 1, PURCHASE_PRICE);
            vm.stopPrank();
        }
    }

    function _deployBankRunSystemWithLimitedVault()
        internal
        returns (
            MockUSDC usdc,
            SeatToken seatToken,
            PrincipalManager principalManager,
            BondingTranche bondingTranche,
            LimitedWithdrawalVault principalVault
        )
    {
        usdc = new MockUSDC();
        seatToken =
            new SeatToken("PEN Seat", "SEAT", TOTAL_PURCHASES, 365 days, admin, address(0), address(0), address(0));
        principalManager = new PrincipalManager(usdc, admin, address(0), RESERVE_TARGET, IERC4626(address(0)));
        principalVault = new LimitedWithdrawalVault(address(usdc));

        uint256[] memory upperBounds = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        upperBounds[0] = TOTAL_PURCHASES;
        prices[0] = PURCHASE_PRICE;

        bondingTranche =
            new BondingTranche(seatToken, principalManager, REFUND_PRICE, admin, reclaimer, upperBounds, prices);

        vm.startPrank(admin);
        seatToken.grantRole(seatToken.MINTER_ROLE(), address(bondingTranche));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));
        principalManager.grantRole(principalManager.BONDING_ROLE(), address(bondingTranche));
        principalManager.setPrincipalVault(principalVault);
        vm.stopPrank();

        for (uint256 i; i < TOTAL_PURCHASES; ++i) {
            usdc.mint(holders[i], PURCHASE_PRICE);

            vm.startPrank(holders[i]);
            usdc.approve(address(bondingTranche), PURCHASE_PRICE);
            bondingTranche.purchase(holders[i], 1, PURCHASE_PRICE);
            vm.stopPrank();
        }
    }
}
