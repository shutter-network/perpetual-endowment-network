// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";

/// @notice Stateless helper delegatecalled from Safe.setup to finish PEN Safe configuration by enabling the Snapshot X execution-strategy module.
contract PENSafeBootstrap {
    function setUp(address executionStrategy_) external {
        Safe(payable(address(this))).enableModule(executionStrategy_);
    }
}
