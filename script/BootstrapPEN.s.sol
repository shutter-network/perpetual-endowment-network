// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SeatToken} from "../src/SeatToken.sol";

import {PENDeploymentHelper, ISpaceManager, IOwnable} from "./PENDeploymentScriptBase.s.sol";

/// @notice Phase-2 finalize logic: bind SeatToken to the deployed Space, enable the Space on
///         the exec strategies, transfer exec-strategy ownership to the Safe. Kept as an
///         abstract helper so the two-phase integration test harness can call the same
///         sequence without going through env-var + JSON I/O.
abstract contract PENBootstrapHelper is PENDeploymentHelper {
    error SpaceNotAContract();
    error UnexpectedSpaceOwner(address actual, address expected);

    function _bootstrapPEN(DeploymentAddresses memory deployed_, address space_) internal {
        if (space_.code.length == 0) revert SpaceNotAContract();
        address actualOwner = IOwnable(space_).owner();
        if (actualOwner != deployed_.safe) revert UnexpectedSpaceOwner(actualOwner, deployed_.safe);

        // 1. Bind SeatToken to the Space. `bootstrap` slot is consumed inside setSpace, so
        //    no residual admin lever remains on SeatToken after this call returns.
        SeatToken(deployed_.seatToken).setSpace(space_);

        // 2. enableSpace on the exec strategy the Space executes through directly (timelock
        //    when enabled, otherwise avatar).
        address spaceExecTarget = deployed_.timelockExecutionStrategy != address(0)
            ? deployed_.timelockExecutionStrategy
            : deployed_.executionStrategy;
        ISpaceManager(spaceExecTarget).enableSpace(space_);

        // 3. If timelock is enabled, chain timelock -> avatar (the avatar sees the timelock
        //    as its "space").
        if (deployed_.timelockExecutionStrategy != address(0)) {
            ISpaceManager(deployed_.executionStrategy).enableSpace(deployed_.timelockExecutionStrategy);
        }

        // 4. Transfer exec-strategy ownership to the Safe. Must run AFTER the enableSpace
        //    calls above — once the Safe owns the strategies, further enableSpace calls
        //    can only be issued via governance.
        IOwnable(deployed_.executionStrategy).transferOwnership(deployed_.safe);
        if (deployed_.timelockExecutionStrategy != address(0)) {
            IOwnable(deployed_.timelockExecutionStrategy).transferOwnership(deployed_.safe);
        }
    }
}

/// @notice Phase-2 finalize script. Reads Phase-1 addresses from `deployments/<chainId>.json`,
///         reads the operator-supplied Space address from `PHASE2_SPACE_ADDRESS`, validates
///         invariants, executes the finalize bundle from the bootstrap EOA, and rewrites the
///         artifact with `space` filled in and `phase2Pending` removed.
contract BootstrapPEN is Script, PENBootstrapHelper {
    error MissingPhase1Artifact(string path);

    function run() external {
        DeploymentAddresses memory deployed = _readDeploymentArtifact();
        address space = vm.envAddress("PHASE2_SPACE_ADDRESS");

        console2.log("=======================================================");
        console2.log("PEN Phase 2 bootstrap");
        console2.log("Chain id:      ", block.chainid);
        console2.log("Space:         ", space);
        console2.log("Safe:          ", deployed.safe);
        console2.log("SeatToken:     ", deployed.seatToken);
        console2.log("-------------------------------------------------------");

        address deployer = _resolveDeployer();
        _startBroadcast(deployer);
        _bootstrapPEN(deployed, space);
        _stopBroadcast();

        _writeFinalizedArtifact(deployed, space);
        console2.log(">>> Phase 2 finalize complete <<<");
    }

    function _readDeploymentArtifact() internal view returns (DeploymentAddresses memory d) {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        try vm.readFile(path) returns (string memory json) {
            d.safeSingleton = vm.parseJsonAddress(json, ".safeSingleton");
            d.safeProxyFactory = vm.parseJsonAddress(json, ".safeProxyFactory");
            d.safeBootstrap = vm.parseJsonAddress(json, ".safeBootstrap");
            d.safe = vm.parseJsonAddress(json, ".safe");
            d.seatToken = vm.parseJsonAddress(json, ".seatToken");
            d.principalManager = vm.parseJsonAddress(json, ".principalManager");
            d.bondingTranche = vm.parseJsonAddress(json, ".bondingTranche");
            d.executionStrategy = vm.parseJsonAddress(json, ".executionStrategy");
            d.timelockExecutionStrategy = vm.parseJsonAddress(json, ".timelockExecutionStrategy");
        } catch {
            revert MissingPhase1Artifact(path);
        }
    }

    /// @dev Rewrites the artifact with the resolved Space address and drops the phase2Pending
    ///      flag. Output shape mirrors `PENDeploymentHelper._writeDeploymentArtifact` minus
    ///      the flag, so downstream consumers see one canonical schema after Phase 2 completes.
    function _writeFinalizedArtifact(DeploymentAddresses memory d, address space) internal {
        string memory json = string.concat(
            "{\n",
            '  "safeSingleton": "',
            vm.toString(d.safeSingleton),
            '",\n',
            '  "safeProxyFactory": "',
            vm.toString(d.safeProxyFactory),
            '",\n',
            '  "safeBootstrap": "',
            vm.toString(d.safeBootstrap),
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
            '  "executionStrategy": "',
            vm.toString(d.executionStrategy),
            '",\n',
            '  "timelockExecutionStrategy": "',
            vm.toString(d.timelockExecutionStrategy),
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
