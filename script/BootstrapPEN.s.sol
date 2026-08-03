// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import {SeatToken} from "../src/SeatToken.sol";

import {PENDeploymentHelper, IOwnable} from "./PENDeploymentScriptBase.s.sol";

/// @notice Phase-2 finalize logic: bind SeatToken to the Space, enable the UI-deployed exec
///         strategy as a Safe module, and swap it in as the Safe's sole owner. Kept as an
///         abstract helper so the two-phase integration test harness can call the same
///         sequence without going through env-var + JSON I/O.
abstract contract PENBootstrapHelper is PENDeploymentHelper {
    address internal constant SENTINEL_OWNERS = address(0x1);

    error SpaceNotAContract();
    error ExecStrategyNotAContract();
    error UnexpectedSpaceOwner(address actual, address expected);
    error SafeTxFailed(bytes32 action);

    function _bootstrapPEN(
        DeploymentAddresses memory deployed_,
        address space_,
        address execStrategy_,
        address deployer_
    ) internal {
        if (space_.code.length == 0) revert SpaceNotAContract();
        if (execStrategy_.code.length == 0) revert ExecStrategyNotAContract();
        address actualOwner = IOwnable(space_).owner();
        if (actualOwner != deployed_.safe) revert UnexpectedSpaceOwner(actualOwner, deployed_.safe);

        // 1. Bind SeatToken to the Space. `bootstrap` slot is consumed inside setSpace, so
        //    no residual admin lever remains on SeatToken after this call returns.
        SeatToken(deployed_.seatToken).setSpace(space_);

        // 2. Enable the UI-deployed exec strategy as a Safe module. Submitted as a Safe tx
        //    signed (via the v=1 msg.sender == owner shortcut) by the deployer, still the
        //    Safe's sole owner at this point.
        _execSafeTx(
            deployed_.safe, abi.encodeWithSignature("enableModule(address)", execStrategy_), deployer_, "enableModule"
        );

        // 3. Swap the Safe's sole owner from `deployer` → `execStrategy`. After this Safe
        //    txs can no longer be authenticated by ECDSA sigs — every operation must route
        //    through the exec-strategy module → Safe path (i.e., governance).
        _execSafeTx(
            deployed_.safe,
            abi.encodeWithSignature("swapOwner(address,address,address)", SENTINEL_OWNERS, deployer_, execStrategy_),
            deployer_,
            "swapOwner"
        );
    }

    /// @dev Submits a Safe transaction addressed to the Safe itself, signed by `deployer_`
    ///      using the "pre-approved by msg.sender" shortcut (Safe `checkNSignatures`, v=1
    ///      branch: `require(msg.sender == currentOwner || approvedHashes[...])`). Deployer
    ///      is the sole owner + threshold=1 at Phase 2 start, so a single 65-byte sig
    ///      encoding the deployer as approver is sufficient.
    function _execSafeTx(address safe_, bytes memory data_, address deployer_, bytes32 action_) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(deployer_))), bytes32(0), uint8(1));
        bool ok = Safe(payable(safe_))
            .execTransaction(safe_, 0, data_, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), sig);
        if (!ok) revert SafeTxFailed(action_);
    }
}

/// @notice Phase-2 finalize script. Reads Phase-1 addresses from `deployments/<chainId>.json`,
///         reads the operator-supplied Space + exec-strategy addresses from env vars,
///         validates invariants, executes the finalize bundle from the deployer EOA, and
///         rewrites the artifact with `space` + `execStrategy` filled in and `phase2Pending`
///         removed.
contract BootstrapPEN is Script, PENBootstrapHelper {
    error MissingPhase1Artifact(string path);

    function run() external {
        DeploymentAddresses memory deployed = _readDeploymentArtifact();
        address space = vm.envAddress("PHASE2_SPACE_ADDRESS");
        address execStrategy = vm.envAddress("PHASE2_EXEC_STRATEGY_ADDRESS");

        console2.log("=======================================================");
        console2.log("PEN Phase 2 bootstrap");
        console2.log("Chain id:      ", block.chainid);
        console2.log("Space:         ", space);
        console2.log("ExecStrategy:  ", execStrategy);
        console2.log("Safe:          ", deployed.safe);
        console2.log("SeatToken:     ", deployed.seatToken);
        console2.log("-------------------------------------------------------");

        address deployer = _resolveDeployer();
        _startBroadcast(deployer);
        _bootstrapPEN(deployed, space, execStrategy, deployer);
        _stopBroadcast();

        _writeFinalizedArtifact(deployed, space, execStrategy);
        console2.log(">>> Phase 2 finalize complete <<<");
    }

    function _readDeploymentArtifact() internal view returns (DeploymentAddresses memory d) {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        try vm.readFile(path) returns (string memory json) {
            d.safeSingleton = vm.parseJsonAddress(json, ".safeSingleton");
            d.safeProxyFactory = vm.parseJsonAddress(json, ".safeProxyFactory");
            d.safe = vm.parseJsonAddress(json, ".safe");
            d.seatToken = vm.parseJsonAddress(json, ".seatToken");
            d.principalManager = vm.parseJsonAddress(json, ".principalManager");
            d.bondingTranche = vm.parseJsonAddress(json, ".bondingTranche");
        } catch {
            revert MissingPhase1Artifact(path);
        }
    }

    /// @dev Rewrites the artifact with the resolved Space + exec-strategy addresses and
    ///      drops the `phase2Pending` flag. Output shape mirrors
    ///      `PENDeploymentScriptBase._writeDeploymentArtifact` minus the flag, so downstream
    ///      consumers see one canonical schema after Phase 2 completes.
    function _writeFinalizedArtifact(DeploymentAddresses memory d, address space, address execStrategy) internal {
        string memory json = string.concat(
            "{\n",
            '  "safeSingleton": "',
            vm.toString(d.safeSingleton),
            '",\n',
            '  "safeProxyFactory": "',
            vm.toString(d.safeProxyFactory),
            '",\n',
            '  "safe": "',
            vm.toString(d.safe),
            '",\n',
            '  "seatToken": "',
            vm.toString(d.seatToken),
            '",\n',
            '  "principalManager": "',
            vm.toString(d.principalManager),
            '",\n',
            '  "bondingTranche": "',
            vm.toString(d.bondingTranche),
            '",\n',
            '  "space": "',
            vm.toString(space),
            '",\n',
            '  "execStrategy": "',
            vm.toString(execStrategy),
            '"\n',
            "}"
        );
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeFile(path, json);
        console2.log("Finalized artifact written to:", path);
    }

    function _resolveDeployer() internal view returns (address deployer_) {
        try vm.envUint("PRIVATE_KEY") returns (uint256 privateKey) {
            return vm.addr(privateKey);
        } catch {
            return vm.envAddress("DEPLOYER");
        }
    }

    function _startBroadcast(address deployer_) internal {
        try vm.envUint("PRIVATE_KEY") returns (uint256 privateKey) {
            vm.startBroadcast(privateKey);
        } catch {
            vm.startBroadcast(deployer_);
        }
    }

    function _stopBroadcast() internal {
        vm.stopBroadcast();
    }
}
