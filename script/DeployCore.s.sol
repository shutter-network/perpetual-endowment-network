// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";

contract DeployCore is Script {
    function run()
        external
        returns (SeatToken seatToken, PrincipalManager principalManager, BondingTranche bondingTranche)
    {
        string memory seatName = vm.envString("SEAT_TOKEN_NAME");
        string memory seatSymbol = vm.envString("SEAT_TOKEN_SYMBOL");
        uint256 seatSupplyCap = vm.envUint("SEAT_TOKEN_SUPPLY_CAP");
        uint256 inactivityPeriod = vm.envUint("SEAT_TOKEN_INACTIVITY_PERIOD");
        uint256 refundPrice = vm.envUint("REFUND_PRICE");
        uint256 reserveTarget = vm.envUint("LIQUID_RESERVE_TARGET");

        address admin = vm.envAddress("ADMIN");
        address strategist = vm.envAddress("STRATEGIST");
        address reclaimer = vm.envAddress("RECLAIMER");
        address paymentAsset = vm.envAddress("PAYMENT_ASSET");

        address principalVaultAddress = _envOrZeroAddress("PRINCIPAL_VAULT");
        address yieldVaultAddress = _envOrZeroAddress("YIELD_VAULT");
        address yieldVaultReceiver = _envOrZeroAddress("YIELD_VAULT_RECEIVER");

        uint256[] memory trancheUpperBounds = vm.envUint("TRANCHE_UPPER_BOUNDS", ",");
        uint256[] memory tranchePrices = vm.envUint("TRANCHE_PRICES", ",");

        vm.startBroadcast();

        seatToken = new SeatToken(
            seatName, seatSymbol, seatSupplyCap, uint48(inactivityPeriod), admin, address(0), address(0), address(0)
        );

        principalManager = new PrincipalManager(IERC20(paymentAsset), admin, address(0), strategist, reserveTarget);

        bondingTranche = new BondingTranche(
            seatToken, principalManager, refundPrice, admin, reclaimer, trancheUpperBounds, tranchePrices
        );

        seatToken.grantRole(seatToken.MINTER_ROLE(), address(bondingTranche));
        seatToken.grantRole(seatToken.BURNER_ROLE(), address(bondingTranche));
        principalManager.grantRole(principalManager.BONDING_ROLE(), address(bondingTranche));

        if (principalVaultAddress != address(0)) {
            principalManager.setPrincipalVault(IERC4626(principalVaultAddress));
        }

        if (yieldVaultAddress != address(0)) {
            principalManager.setYieldVault(IERC4626(yieldVaultAddress), yieldVaultReceiver);
        }

        vm.stopBroadcast();

        console2.log("SeatToken:", address(seatToken));
        console2.log("PrincipalManager:", address(principalManager));
        console2.log("BondingTranche:", address(bondingTranche));
    }

    function _envOrZeroAddress(string memory key) internal view returns (address value) {
        try vm.envAddress(key) returns (address parsed) {
            return parsed;
        } catch {
            return address(0);
        }
    }
}
