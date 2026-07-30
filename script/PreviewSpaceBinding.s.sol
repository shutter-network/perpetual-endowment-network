// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Minimal view surface of the sx-evm Space needed by the preview script.
/// @dev    Declared locally to avoid the source-unit-id conflict that bare-import
///         `ISpaceState` from sx-evm would introduce (see the same workaround in
///         `PENDeploymentScriptBase` for the write side).
interface ISpaceView {
    function owner() external view returns (address);
    function authenticators(address) external view returns (uint256);
    function votingStrategies(uint8) external view returns (address addr, bytes memory params);
    function activeVotingStrategies() external view returns (uint256);
    function proposalValidationStrategy() external view returns (address addr, bytes memory params);
    function votingDelay() external view returns (uint32);
    function minVotingDuration() external view returns (uint32);
    function maxVotingDuration() external view returns (uint32);
    function nextVotingStrategyIndex() external view returns (uint8);
}

/// @notice Read-only preview of a candidate Space. Prints the fields an operator must
///         eyeball before firing `SeatToken.setSpace` in Phase 2 finalize.
/// @dev    Env: `PHASE2_SPACE_ADDRESS`. Optional cross-checks: `SX_ETH_TX_AUTHENTICATOR`,
///         `SX_OZ_VOTES_STRATEGY`, `SX_PROPOSITION_POWER_VALIDATION`. `metadataURI`
///         and `daoURI` are not exposed as view functions on Space — Snapshot X only
///         emits them as events — so they're flagged for event-scan verification.
contract PreviewSpaceBinding is Script {
    function run() external view {
        address space = vm.envAddress("PHASE2_SPACE_ADDRESS");

        console2.log("=======================================================");
        console2.log("PEN Phase 2 Space preview");
        console2.log("Chain id:      ", block.chainid);
        console2.log("Space:         ", space);
        console2.log("-------------------------------------------------------");

        if (space.code.length == 0) {
            console2.log("[FAIL] Space has no bytecode at this address.");
            return;
        }

        ISpaceView sp = ISpaceView(space);

        // ── owner ─────────────────────────────────────────────────────────────
        console2.log("owner:                       ", sp.owner());

        // ── voting-window params ──────────────────────────────────────────────
        console2.log("votingDelay:                 ", sp.votingDelay());
        console2.log("minVotingDuration:           ", sp.minVotingDuration());
        console2.log("maxVotingDuration:           ", sp.maxVotingDuration());

        // ── voting strategies ─────────────────────────────────────────────────
        uint8 next = sp.nextVotingStrategyIndex();
        uint256 activeBitmap = sp.activeVotingStrategies();
        console2.log("nextVotingStrategyIndex:     ", uint256(next));
        console2.log("activeVotingStrategies bitmap:", activeBitmap);
        for (uint8 i; i < next; i++) {
            (address addr, bytes memory params) = sp.votingStrategies(i);
            bool isActive = (activeBitmap & (uint256(1) << i)) != 0;
            console2.log("");
            console2.log(" votingStrategies[i]:");
            console2.log("   index:  ", uint256(i));
            console2.log("   active: ", isActive);
            console2.log("   addr:   ", addr);
            console2.log("   params:");
            console2.logBytes(params);
        }

        // ── proposal validation strategy ──────────────────────────────────────
        (address pvAddr, bytes memory pvParams) = sp.proposalValidationStrategy();
        console2.log("");
        console2.log("proposalValidationStrategy:");
        console2.log("   addr:   ", pvAddr);
        console2.log("   params:");
        console2.logBytes(pvParams);

        // ── authenticators (whitelist check against known-canonical addresses) ─
        console2.log("");
        console2.log("authenticators (canonical whitelist checks):");
        _checkAuthenticator("SX_ETH_TX_AUTHENTICATOR", sp);
        _checkAuthenticator("SX_ETH_SIG_AUTHENTICATOR", sp);
        _checkAuthenticator("SX_VANILLA_AUTHENTICATOR", sp);

        // ── metadata (event-only) ─────────────────────────────────────────────
        console2.log("");
        console2.log("metadataURI / daoURI: not exposed as view functions on Space.");
        console2.log("Verify by scanning `MetadataURIUpdated` and `DaoURIUpdated` events.");
        console2.log("=======================================================");
    }

    function _checkAuthenticator(string memory envKey, ISpaceView sp) internal view {
        try vm.envAddress(envKey) returns (address candidate) {
            bool enabled = sp.authenticators(candidate) != 0;
            console2.log("  ", envKey, candidate);
            console2.log("     enabled:", enabled);
        } catch {
            console2.log("  ", envKey, "(env not set - skipping)");
        }
    }
}
