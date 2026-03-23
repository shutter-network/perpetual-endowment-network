// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PENDeploymentScriptBase} from "./PENDeploymentScriptBase.s.sol";

contract DeployPENSystem is PENDeploymentScriptBase {
    function run() external returns (DeploymentAddresses memory deployed) {
        DeploymentConfig memory config = _loadConfig();
        bytes32 deploymentSalt = vm.envBytes32("DEPLOYMENT_SALT");
        address deployer = _resolveDeployer();
        uint256 startingNonce = _currentDeployerNonce(deployer);
        DeploymentAddresses memory expected = previewDeployment(deployer, startingNonce, deploymentSalt, config);

        _logDeploymentPlan(deployer, startingNonce, deploymentSalt);

        _startBroadcast(deployer);
        deployed = _deploySystem(expected, deploymentSalt, config, deployer);
        _stopBroadcast();

        _logAddresses(deployed);
    }
}
