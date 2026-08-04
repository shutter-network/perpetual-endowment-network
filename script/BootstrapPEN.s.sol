// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";

import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";

import {Strategy} from "@snapshot-x/types.sol";

import {SeatToken} from "../src/SeatToken.sol";

import {PENDeploymentScriptBase, PENDeploymentHelper, IOwnable, ISpaceManager} from "./PENDeploymentScriptBase.s.sol";

// ── Minimal views used by the Phase-2 governance-wiring preflight ────────────────────────────
// Declared locally (rather than importing the concrete sx-evm Space / execution-strategy
// contracts) to avoid the sx-evm bare-import source-unit conflict documented in
// `PENDeploymentScriptBase`. `owner()` / `isSpaceEnabled()` come from `IOwnable` /
// `ISpaceManager`; these cover the remaining fields the preflight cross-checks.

interface ISpaceConfigView {
    function authenticators(address) external view returns (uint256);
    function votingStrategies(uint8) external view returns (address addr, bytes memory params);
    function activeVotingStrategies() external view returns (uint256);
    function proposalValidationStrategy() external view returns (address addr, bytes memory params);
    function votingDelay() external view returns (uint32);
    function minVotingDuration() external view returns (uint32);
    function maxVotingDuration() external view returns (uint32);
    function nextVotingStrategyIndex() external view returns (uint8);
}

interface IAvatarExecConfigView {
    function target() external view returns (address);
    function quorum() external view returns (uint256);
}

interface ITimelockExecConfigView {
    function timelockDelay() external view returns (uint256);
    function quorum() external view returns (uint256);
    function vetoGuardian() external view returns (address);
}

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
    error ExecStrategySpaceNotEnabled(address execStrategy, address space);
    error UnexpectedExecStrategyOwner(address actual, address expected);
    error UnexpectedExecStrategyTarget(address actual, address expected);
    error SpaceConfigMismatch(bytes32 field);
    error ExecStrategyConfigMismatch(bytes32 field);

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

        // The exec strategy is about to be handed sole ownership of the Safe. Assert — before
        // any irreversible step — that it already controls THIS Safe and has THIS Space
        // enabled. Both AvatarExecutionStrategy and TimelockExecutionStrategy are Ownable
        // SpaceManagers, so these two checks are config-independent and hold for either
        // strategy type. Without them a mis-pasted `execStrategy_` (e.g. the Space and
        // exec-strategy proxy addresses swapped — they surface from the same non-indexed
        // event across two consecutive `snapshot.box` txs) would capture the Safe on swapOwner.
        address execOwner = IOwnable(execStrategy_).owner();
        if (execOwner != deployed_.safe) revert UnexpectedExecStrategyOwner(execOwner, deployed_.safe);
        if (ISpaceManager(execStrategy_).isSpaceEnabled(space_) != 1) {
            revert ExecStrategySpaceNotEnabled(execStrategy_, space_);
        }

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

    // ── Governance-wiring preflight ──────────────────────────────────────────────────────
    // Cross-checks the operator-supplied Space + exec strategy against the governance config
    // in the env BEFORE any state change. `_bootstrapPEN` already asserts the config-
    // independent structural link (exec-strategy owner == Safe, Space enabled on the exec
    // strategy); this preflight additionally verifies every governance parameter that the
    // env says should be baked into the Space or the exec strategy, so a wrong-but-Safe-owned
    // Space/strategy (or a stale UI value) is caught before the irreversible swapOwner. It is
    // a superset of the structural link check, so it is safe to run standalone.

    function _assertGovernanceConfig(
        DeploymentAddresses memory deployed_,
        address space_,
        address execStrategy_,
        GovernanceConfig memory gov_
    ) internal view {
        _assertSpaceConfig(deployed_, space_, gov_);
        _assertExecStrategyConfig(deployed_, space_, execStrategy_, gov_);
    }

    function _assertSpaceConfig(DeploymentAddresses memory deployed_, address space_, GovernanceConfig memory gov_)
        internal
        view
    {
        if (IOwnable(space_).owner() != deployed_.safe) {
            revert UnexpectedSpaceOwner(IOwnable(space_).owner(), deployed_.safe);
        }

        ISpaceConfigView sp = ISpaceConfigView(space_);

        // Authenticator: the stock EthTxAuthenticator from the env must be whitelisted.
        if (sp.authenticators(gov_.sxEthTxAuthenticator) == 0) revert SpaceConfigMismatch("ethTxAuthenticator");

        // Voting strategy 0 == stock OZVotes over exactly this SeatToken; exactly one active.
        (address vsAddr, bytes memory vsParams) = sp.votingStrategies(0);
        if (vsAddr != gov_.sxOzVotesStrategy) revert SpaceConfigMismatch("ozVotesStrategy");
        if (_decodeToken(vsParams) != deployed_.seatToken) revert SpaceConfigMismatch("votingStrategyToken");
        if (sp.activeVotingStrategies() != 1) revert SpaceConfigMismatch("activeVotingStrategies");
        if (sp.nextVotingStrategyIndex() != 1) revert SpaceConfigMismatch("nextVotingStrategyIndex");

        // Proposal validation == stock Proposition Power, config threshold, OZVotes/SeatToken.
        (address pvAddr, bytes memory pvParams) = sp.proposalValidationStrategy();
        if (pvAddr != gov_.sxPropositionPowerValidation) revert SpaceConfigMismatch("proposalValidation");
        (uint256 threshold, Strategy[] memory strats) = abi.decode(pvParams, (uint256, Strategy[]));
        if (threshold != gov_.proposerSeatThreshold) revert SpaceConfigMismatch("proposerThreshold");
        if (
            strats.length != 1 || strats[0].addr != gov_.sxOzVotesStrategy
                || _decodeToken(strats[0].params) != deployed_.seatToken
        ) {
            revert SpaceConfigMismatch("proposalValidationStrategy");
        }

        // Voting-window params. NOTE: Snapshot X measures these in BLOCKS, not seconds
        // (sx-evm `Space.propose`: startBlockNumber = block.number + votingDelay). The env
        // values (VOTING_DELAY / MIN|MAX_VOTING_DURATION) must therefore be block counts, i.e.
        // human-duration / block-time (≈ seconds/12 on a 12s chain) — matching what the
        // snapshot.box UI stores. TIMELOCK_DELAY, by contrast, is time-based (seconds).
        if (sp.votingDelay() != gov_.votingDelay) revert SpaceConfigMismatch("votingDelay");
        if (sp.minVotingDuration() != gov_.minVotingDuration) revert SpaceConfigMismatch("minVotingDuration");
        if (sp.maxVotingDuration() != gov_.maxVotingDuration) revert SpaceConfigMismatch("maxVotingDuration");
    }

    function _assertExecStrategyConfig(
        DeploymentAddresses memory deployed_,
        address space_,
        address execStrategy_,
        GovernanceConfig memory gov_
    ) internal view {
        // Structural link (also enforced in `_bootstrapPEN`) — repeated so this preflight is
        // complete on its own.
        if (ISpaceManager(execStrategy_).isSpaceEnabled(space_) != 1) {
            revert ExecStrategySpaceNotEnabled(execStrategy_, space_);
        }
        address execOwner = IOwnable(execStrategy_).owner();
        if (execOwner != deployed_.safe) revert UnexpectedExecStrategyOwner(execOwner, deployed_.safe);

        if (gov_.timelockEnabled) {
            ITimelockExecConfigView tl = ITimelockExecConfigView(execStrategy_);
            if (tl.timelockDelay() != gov_.timelockDelay) revert ExecStrategyConfigMismatch("timelockDelay");
            if (tl.quorum() != gov_.avatarQuorum) revert ExecStrategyConfigMismatch("quorum");
            if (tl.vetoGuardian() != address(0)) revert ExecStrategyConfigMismatch("vetoGuardian");
        } else {
            IAvatarExecConfigView av = IAvatarExecConfigView(execStrategy_);
            if (av.target() != deployed_.safe) revert UnexpectedExecStrategyTarget(av.target(), deployed_.safe);
            if (av.quorum() != gov_.avatarQuorum) revert ExecStrategyConfigMismatch("quorum");
        }
    }

    /// @dev A voting-strategy `params` blob is `abi.encodePacked(token, ...)`; the ERC20Votes
    ///      token address is its leading 20 bytes. Mirrors the decode in `VerifyPENSystem`.
    function _decodeToken(bytes memory params) internal pure returns (address) {
        if (params.length < 20) return address(0);
        return address(bytes20(params));
    }
}

/// @notice Phase-2 finalize script. Reads Phase-1 addresses from `deployments/<chainId>.json`,
///         reads the operator-supplied Space + exec-strategy addresses from env vars,
///         validates invariants, executes the finalize bundle from the deployer EOA, and
///         rewrites the artifact with `space` + `execStrategy` filled in and `phase2Pending`
///         removed.
contract BootstrapPEN is PENDeploymentScriptBase, PENBootstrapHelper {
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

        // Preflight: cross-check the operator-supplied Space + exec strategy against the
        // governance config in the env before touching any state. `forge script` simulates
        // the whole `run()` before broadcasting, so a revert here aborts the run and NOTHING
        // is sent — the irreversible `swapOwner` never fires against a mis-pasted or
        // mis-configured address.
        DeploymentConfig memory config = _loadConfig();
        _assertGovernanceConfig(deployed, space, execStrategy, config.governance);
        console2.log("Governance-wiring preflight passed.");

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
}
