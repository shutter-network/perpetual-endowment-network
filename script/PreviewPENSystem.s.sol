// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PENDeploymentScriptBase} from "./PENDeploymentScriptBase.s.sol";

contract PreviewPENSystem is PENDeploymentScriptBase {
    function run() external returns (DeploymentAddresses memory deployed) {
        bytes32 deploymentSalt = vm.envBytes32("DEPLOYMENT_SALT");
        address deployer = _resolveDeployer();
        uint256 startingNonce = _previewNonce(deployer);
        DeploymentConfig memory config = _loadConfig();

        deployed = previewDeployment(deployer, startingNonce, deploymentSalt, config);

        _logDeploymentPlan(deployer, startingNonce, deploymentSalt);
        _logAddresses(deployed);

        _checkDeployerFunds(deployer, deploymentSalt, config);
    }
}
