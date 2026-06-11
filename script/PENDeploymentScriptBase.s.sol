// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {RLP} from "openzeppelin-contracts/contracts/utils/RLP.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {SeatVotingStrategy} from "../src/governance/SeatVotingStrategy.sol";
import {PENTxAuthenticator} from "../src/governance/PENTxAuthenticator.sol";
import {ISeatToken} from "../src/interfaces/ISeatToken.sol";
import {PENSafeBootstrap} from "../src/deployment/PENSafeBootstrap.sol";

import {Strategy, InitializeCalldata} from "@snapshot-x/types.sol";
import {IProxyFactory} from "@snapshot-x/interfaces/IProxyFactory.sol";
import {AvatarExecutionStrategy} from "@snapshot-x/execution-strategies/AvatarExecutionStrategy.sol";
import {TimelockExecutionStrategy} from "@snapshot-x/execution-strategies/timelocks/TimelockExecutionStrategy.sol";

import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import {SafeProxy} from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";

/// @dev Minimal interface for SpaceManager on execution strategies.
interface ISpaceManager {
    function enableSpace(address space) external;
    function isSpaceEnabled(address space) external view returns (uint256);
}

/// @dev Minimal interface for OwnableUpgradeable on execution strategies.
interface IOwnable {
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}

// Minimal Space initializer declared locally rather than imported from ISpaceActions.
// ISpaceActions.sol uses a bare "src/types.sol" import that solc assigns a different
// source unit ID than our remapped import, causing abi.encodeCall to reject the type.
// Declaring the interface against the already imported InitializeCalldata eliminates the conflict.
// TODO(upstream-fix): once snapshot-labs/sx-evm replaces bare "src/types.sol" imports
// with relative imports, delete this local stub and replace the abi.encodeCall below with:
//   import {ISpaceActions} from "@snapshot-x/interfaces/space/ISpaceActions.sol";
//   abi.encodeCall(ISpaceActions.initialize, (spaceInit))
interface ISpace {
    function initialize(InitializeCalldata calldata input) external;
}

abstract contract PENDeploymentHelper {
    error UnexpectedDeploymentAddress(bytes32 component, address expected, address actual);

    struct CoreConfig {
        string seatName;
        string seatSymbol;
        uint256 seatSupplyCap;
        uint48 inactivityPeriod;
        uint256 refundPrice;
        uint256 liquidReserveTarget;
        address paymentAsset;
        address principalVault;
        uint256[] trancheUpperBounds;
        uint256[] tranchePrices;
    }

    struct GovernanceConfig {
        address sxProxyFactory;
        address sxMasterSpace;
        address sxAvatarImpl;
        address sxTimelockImpl;
        address sxPropositionPowerValidation;
        uint32 votingDelay;
        uint32 minVotingDuration;
        uint32 maxVotingDuration;
        uint256 avatarQuorum;
        uint256 proposerSeatThreshold;
        bool timelockEnabled; // Timelock (optional — set timelockEnabled = false to use AvatarExecutionStrategy directly)
        uint32 timelockDelay;
    }

    struct DeploymentConfig {
        CoreConfig core;
        GovernanceConfig governance;
    }

    struct DeploymentAddresses {
        address safeSingleton;
        address safeProxyFactory;
        address safeBootstrap;
        address safe;
        address seatToken;
        address principalManager;
        address bondingTranche;
        address seatVotingStrategy;
        address penTxAuthenticator;
        address space;                     // Snapshot X Space, cloned from sxMasterSpace
        address executionStrategy;         // AvatarExecutionStrategy proxy
        address timelockExecutionStrategy; // TimelockExecutionStrategy proxy; 0x0 if disabled
    }

    // ── Address prediction ─────────────────────────────────────────────────────────────

    function previewDeployment(
        address deployer_,
        uint256 startingNonce_,
        bytes32 salt_,
        DeploymentConfig memory config_
    ) public view returns (DeploymentAddresses memory predicted_) {
        uint256 nextNonce = startingNonce_;

        predicted_.safeSingleton = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.safeProxyFactory = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.safeBootstrap = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.seatVotingStrategy = _computeCreateAddress(deployer_, nextNonce++);

        // Each ProxyFactory.deployProxy call is a deployer tx (advances nonce), but the
        // proxy address is CREATE2-based (salt = keccak256(deployer, saltNonce)).
        nextNonce++; // avatar proxy tx
        predicted_.executionStrategy = _computeProxyAddress(
            config_.governance.sxProxyFactory, config_.governance.sxAvatarImpl, deployer_, 0
        );

        if (config_.governance.timelockEnabled) {
            nextNonce++; // timelock proxy tx
            predicted_.timelockExecutionStrategy = _computeProxyAddress(
                config_.governance.sxProxyFactory, config_.governance.sxTimelockImpl, deployer_, 1
            );
        }

        nextNonce++; // safeProxyFactory.createProxyWithNonce tx (Safe uses CREATE2 internally)
        predicted_.safe = _predictSafeAddress(predicted_, salt_);

        predicted_.seatToken           = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.principalManager    = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.bondingTranche      = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.penTxAuthenticator  = _computeCreateAddress(deployer_, nextNonce++);

        uint256 spaceSaltNonce = config_.governance.timelockEnabled ? 2 : 1;
        nextNonce++; // space proxy tx
        predicted_.space = _computeProxyAddress(
            config_.governance.sxProxyFactory, config_.governance.sxMasterSpace, deployer_, spaceSaltNonce
        );
    }

    // ── Deployment ─────────────────────────────────────────────────────────────────────

    function _deploySystem(
        DeploymentAddresses memory expected_,
        bytes32 salt_,
        DeploymentConfig memory config_,
        address bootstrapAuthority_
    ) internal returns (DeploymentAddresses memory deployed_) {
        deployed_.safeSingleton = address(new Safe());
        _assertDeployedAddress("SAFE_SINGLETON", expected_.safeSingleton, deployed_.safeSingleton);

        deployed_.safeProxyFactory = address(new SafeProxyFactory());
        _assertDeployedAddress("SAFE_PROXY_FACTORY", expected_.safeProxyFactory, deployed_.safeProxyFactory);

        deployed_.safeBootstrap = address(new PENSafeBootstrap());
        _assertDeployedAddress("SAFE_BOOTSTRAP", expected_.safeBootstrap, deployed_.safeBootstrap);

        // Steps 4–6: SeatVotingStrategy + execution strategy proxies
        (deployed_.seatVotingStrategy, deployed_.executionStrategy, deployed_.timelockExecutionStrategy) =
            _deployGovernanceContracts(expected_, config_, bootstrapAuthority_);

        // Step 7: Safe proxy (owners = [module], module enabled via delegatecall to PENSafeBootstrap)
        deployed_.safe = address(
            SafeProxyFactory(deployed_.safeProxyFactory)
                .createProxyWithNonce(deployed_.safeSingleton, _safeInitializer(expected_), uint256(salt_))
        );
        _assertDeployedAddress("SAFE", expected_.safe, deployed_.safe);

        // Steps 8–10: Core contracts
        (deployed_.seatToken, deployed_.principalManager, deployed_.bondingTranche) =
            _deployCoreContracts(expected_, config_, bootstrapAuthority_);

        // Step 11: PENTxAuthenticator
        deployed_.penTxAuthenticator = address(new PENTxAuthenticator(ISeatToken(deployed_.seatToken), expected_.space));
        _assertDeployedAddress("PEN_TX_AUTHENTICATOR", expected_.penTxAuthenticator, deployed_.penTxAuthenticator);

        // Step 12: Space proxy
        deployed_.space = _deploySpace(deployed_, config_, bootstrapAuthority_);
        _assertDeployedAddress("SPACE", expected_.space, deployed_.space);

        // Steps 13–15: Wire whitelists, transfer ownership, finalise roles
        _initializeGovernance(deployed_);
        _finalizeAccess(deployed_, bootstrapAuthority_);

        return expected_;
    }

    function _deployGovernanceContracts(
        DeploymentAddresses memory expected_,
        DeploymentConfig memory config_,
        address deployer_
    ) internal returns (
        address seatVotingStrategy_,
        address executionStrategy_,
        address timelockExecutionStrategy_
    ) {
        seatVotingStrategy_ = address(new SeatVotingStrategy());
        _assertDeployedAddress("SEAT_VOTING_STRATEGY", expected_.seatVotingStrategy, seatVotingStrategy_);

        IProxyFactory proxyFactory = IProxyFactory(config_.governance.sxProxyFactory);

        // AvatarExecutionStrategy: owner = deployer (transferred to Safe in _initializeGovernance),
        // target = Safe, no spaces yet (added via enableSpace after Space is deployed).
        bytes memory avatarInitParams = abi.encode(
            deployer_, expected_.safe, new address[](0), config_.governance.avatarQuorum
        );
        proxyFactory.deployProxy(
            config_.governance.sxAvatarImpl,
            abi.encodeCall(AvatarExecutionStrategy.setUp, (avatarInitParams)),
            0
        );
        executionStrategy_ = _computeProxyAddress(
            config_.governance.sxProxyFactory, config_.governance.sxAvatarImpl, deployer_, 0
        );
        _assertDeployedAddress("EXECUTION_STRATEGY", expected_.executionStrategy, executionStrategy_);

        if (config_.governance.timelockEnabled) {
            bytes memory timelockInitParams = abi.encode(
                deployer_,
                address(0), // vetoGuardian — deferred per PLAN.md §0
                new address[](0),
                config_.governance.timelockDelay,
                config_.governance.avatarQuorum
            );
            proxyFactory.deployProxy(
                config_.governance.sxTimelockImpl,
                abi.encodeCall(TimelockExecutionStrategy.setUp, (timelockInitParams)),
                1
            );
            timelockExecutionStrategy_ = _computeProxyAddress(
                config_.governance.sxProxyFactory, config_.governance.sxTimelockImpl, deployer_, 1
            );
            _assertDeployedAddress(
                "TIMELOCK_EXEC_STRATEGY", expected_.timelockExecutionStrategy, timelockExecutionStrategy_
            );
        }
    }

    function _deployCoreContracts(
        DeploymentAddresses memory expected_,
        DeploymentConfig memory config_,
        address bootstrapAuthority_
    ) internal returns (address seatToken_, address principalManager_, address bondingTranche_) {
        seatToken_ = address(
            new SeatToken(
                config_.core.seatName,
                config_.core.seatSymbol,
                config_.core.seatSupplyCap,
                config_.core.inactivityPeriod,
                bootstrapAuthority_,
                address(0),
                address(0),
                address(0) // ACTIVITY_ROLE: granted to PENTxAuthenticator in _finalizeAccess
            )
        );
        _assertDeployedAddress("SEAT_TOKEN", expected_.seatToken, seatToken_);

        principalManager_ = address(
            new PrincipalManager(
                IERC20(config_.core.paymentAsset),
                bootstrapAuthority_,
                address(0),
                config_.core.liquidReserveTarget,
                IERC4626(config_.core.principalVault)
            )
        );
        _assertDeployedAddress("PRINCIPAL_MANAGER", expected_.principalManager, principalManager_);

        bondingTranche_ = address(
            new BondingTranche(
                SeatToken(expected_.seatToken),
                PrincipalManager(expected_.principalManager),
                config_.core.refundPrice,
                bootstrapAuthority_,
                bootstrapAuthority_,
                config_.core.trancheUpperBounds,
                config_.core.tranchePrices
            )
        );
        _assertDeployedAddress("BONDING_TRANCHE", expected_.bondingTranche, bondingTranche_);
    }

    function _deploySpace(
        DeploymentAddresses memory deployed_,
        DeploymentConfig memory config_,
        address deployer_
    ) internal returns (address space_) {
        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy({addr: deployed_.seatVotingStrategy, params: abi.encode(deployed_.seatToken)});

        // PropositionPower params: (threshold, allowedStrategies[])
        Strategy[] memory propPowerStrategies = new Strategy[](1);
        propPowerStrategies[0] =
            Strategy({addr: deployed_.seatVotingStrategy, params: abi.encode(deployed_.seatToken)});

        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = "";

        address[] memory authenticators = new address[](1);
        authenticators[0] = deployed_.penTxAuthenticator;

        InitializeCalldata memory spaceInit = InitializeCalldata({
            owner: deployed_.safe,
            votingDelay: config_.governance.votingDelay,
            minVotingDuration: config_.governance.minVotingDuration,
            maxVotingDuration: config_.governance.maxVotingDuration,
            proposalValidationStrategy: Strategy({
                addr: config_.governance.sxPropositionPowerValidation,
                params: abi.encode(config_.governance.proposerSeatThreshold, propPowerStrategies)
            }),
            proposalValidationStrategyMetadataURI: "",
            daoURI: "",
            metadataURI: "",
            votingStrategies: votingStrategies,
            votingStrategyMetadataURIs: votingStrategyMetadataURIs,
            authenticators: authenticators
        });

        uint256 spaceSaltNonce = config_.governance.timelockEnabled ? 2 : 1;
        IProxyFactory(config_.governance.sxProxyFactory).deployProxy(
            config_.governance.sxMasterSpace,
            abi.encodeCall(ISpace.initialize, (spaceInit)),
            spaceSaltNonce
        );

        space_ = _computeProxyAddress(
            config_.governance.sxProxyFactory, config_.governance.sxMasterSpace, deployer_, spaceSaltNonce
        );
    }

    function _initializeGovernance(DeploymentAddresses memory deployed_) internal {
        // The Space directly calls either the timelock (if enabled) or the avatar.
        address spaceExecutionTarget = deployed_.timelockExecutionStrategy != address(0)
            ? deployed_.timelockExecutionStrategy
            : deployed_.executionStrategy;

        // Space → spaceExecutionTarget
        ISpaceManager(spaceExecutionTarget).enableSpace(deployed_.space);

        // If timelock wraps avatar: timelock → avatar
        if (deployed_.timelockExecutionStrategy != address(0)) {
            ISpaceManager(deployed_.executionStrategy).enableSpace(deployed_.timelockExecutionStrategy);
        }

        // Transfer execution strategy ownership from deployer to Safe
        IOwnable(deployed_.executionStrategy).transferOwnership(deployed_.safe);
        if (deployed_.timelockExecutionStrategy != address(0)) {
            IOwnable(deployed_.timelockExecutionStrategy).transferOwnership(deployed_.safe);
        }
    }

    function _finalizeAccess(DeploymentAddresses memory deployed_, address bootstrapAuthority_) internal {
        SeatToken seatToken = SeatToken(deployed_.seatToken);
        PrincipalManager principalManager = PrincipalManager(deployed_.principalManager);
        BondingTranche bondingTranche = BondingTranche(deployed_.bondingTranche);

        seatToken.grantRole(seatToken.MINTER_ROLE(), deployed_.bondingTranche);
        seatToken.grantRole(seatToken.BURNER_ROLE(), deployed_.bondingTranche);
        seatToken.grantRole(seatToken.ACTIVITY_ROLE(), deployed_.penTxAuthenticator);
        seatToken.grantRole(seatToken.DEFAULT_ADMIN_ROLE(), deployed_.safe);
        seatToken.renounceRole(seatToken.DEFAULT_ADMIN_ROLE(), bootstrapAuthority_);

        principalManager.grantRole(principalManager.BONDING_ROLE(), deployed_.bondingTranche);
        principalManager.grantRole(principalManager.DEFAULT_ADMIN_ROLE(), deployed_.safe);
        principalManager.renounceRole(principalManager.DEFAULT_ADMIN_ROLE(), bootstrapAuthority_);

        bondingTranche.grantRole(bondingTranche.RECLAIMER_ROLE(), deployed_.safe);
        bondingTranche.grantRole(bondingTranche.DEFAULT_ADMIN_ROLE(), deployed_.safe);
        bondingTranche.revokeRole(bondingTranche.RECLAIMER_ROLE(), bootstrapAuthority_);
        bondingTranche.renounceRole(bondingTranche.DEFAULT_ADMIN_ROLE(), bootstrapAuthority_);
    }

    // ── Safe initializer ───────────────────────────────────────────────────────────────

    function _safeInitializer(DeploymentAddresses memory predicted_) internal pure returns (bytes memory) {
        // The Safe's single owner is the execution strategy (or timelock if enabled).
        // PENSafeBootstrap.setUp enables it as a module via delegatecall during Safe.setup.
        address moduleToEnable = predicted_.timelockExecutionStrategy != address(0)
            ? predicted_.timelockExecutionStrategy
            : predicted_.executionStrategy;

        address[] memory owners = new address[](1);
        owners[0] = moduleToEnable;

        bytes memory bootstrapData = abi.encodeCall(PENSafeBootstrap.setUp, (moduleToEnable));

        return abi.encodeCall(
            Safe.setup,
            (owners, 1, predicted_.safeBootstrap, bootstrapData, address(0), address(0), 0, payable(address(0)))
        );
    }

    function _predictSafeAddress(DeploymentAddresses memory predicted_, bytes32 salt_) internal pure returns (address) {
        bytes memory initializer = _safeInitializer(predicted_);
        bytes32 proxySalt = keccak256(abi.encodePacked(keccak256(initializer), uint256(salt_)));
        bytes32 proxyInitCodeHash =
            keccak256(abi.encodePacked(type(SafeProxy).creationCode, uint256(uint160(predicted_.safeSingleton))));
        return Create2.computeAddress(proxySalt, proxyInitCodeHash, predicted_.safeProxyFactory);
    }

    // ── Address computation helpers ────────────────────────────────────────────────────

    function _computeCreateAddress(address deployer_, uint256 nonce_) internal pure returns (address) {
        bytes[] memory encoded = new bytes[](2);
        encoded[0] = RLP.encode(deployer_);
        encoded[1] = RLP.encode(nonce_);

        return address(uint160(uint256(keccak256(RLP.encode(encoded)))));
    }

    function _computeProxyAddress(
        address sxProxyFactory_,
        address implementation_,
        address deployer_,
        uint256 saltNonce_
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(deployer_, saltNonce_));
        return IProxyFactory(sxProxyFactory_).predictProxyAddress(implementation_, salt);
    }

    function _assertDeployedAddress(bytes32 component_, address expected_, address actual_) internal pure {
        if (expected_ != actual_) revert UnexpectedDeploymentAddress(component_, expected_, actual_);
    }
}

abstract contract PENDeploymentScriptBase is Script, PENDeploymentHelper {
    error InsufficientDeployerBalance(uint256 requiredWei, uint256 availableWei);

    /// @dev Default 1.2x gas buffer. Covers per-tx overhead (forge script broadcasts each `new Contract()` and
    ///      role-management call as a separate transaction; each adds ~21k base gas + calldata cost). Override
    ///      via env `GAS_BUFFER_BPS` (e.g. 15000 = 1.5x).
    uint256 internal constant _DEFAULT_GAS_BUFFER_BPS = 12_000;
    uint256 internal constant _BPS_DENOMINATOR = 10_000;

    // ── Config loading ─────────────────────────────────────────────────────────────────

    function _loadConfig() internal view returns (DeploymentConfig memory config) {
        config.core = CoreConfig({
            seatName: vm.envString("SEAT_TOKEN_NAME"),
            seatSymbol: vm.envString("SEAT_TOKEN_SYMBOL"),
            seatSupplyCap: vm.envUint("SEAT_TOKEN_SUPPLY_CAP"),
            inactivityPeriod: uint48(vm.envUint("SEAT_TOKEN_INACTIVITY_PERIOD")),
            refundPrice: vm.envUint("REFUND_PRICE"),
            liquidReserveTarget: vm.envUint("LIQUID_RESERVE_TARGET"),
            paymentAsset: vm.envAddress("PAYMENT_ASSET"),
            principalVault: _envOrZeroAddress("PRINCIPAL_VAULT"),
            trancheUpperBounds: vm.envUint("TRANCHE_UPPER_BOUNDS", ","),
            tranchePrices: vm.envUint("TRANCHE_PRICES", ",")
        });

        bool timelockEnabled_ = _envBoolOrFalse("TIMELOCK_ENABLED");
        config.governance = GovernanceConfig({
            sxProxyFactory: vm.envAddress("SX_PROXY_FACTORY"),
            sxMasterSpace: vm.envAddress("SX_MASTER_SPACE"),
            sxAvatarImpl: vm.envAddress("SX_AVATAR_IMPL"),
            sxTimelockImpl: vm.envAddress("SX_TIMELOCK_IMPL"),
            sxPropositionPowerValidation: vm.envAddress("SX_PROPOSITION_POWER_VALIDATION"),
            votingDelay: uint32(vm.envUint("VOTING_DELAY")),
            minVotingDuration: uint32(vm.envUint("MIN_VOTING_DURATION")),
            maxVotingDuration: uint32(vm.envUint("MAX_VOTING_DURATION")),
            avatarQuorum: vm.envUint("AVATAR_QUORUM"),
            proposerSeatThreshold: vm.envUint("PROPOSER_SEAT_THRESHOLD"),
            timelockEnabled: timelockEnabled_,
            timelockDelay: timelockEnabled_ ? uint32(vm.envUint("TIMELOCK_DELAY")) : 0
        });
    }

    // ── Deployer resolution ────────────────────────────────────────────────────────────

    function _resolveDeployer() internal view returns (address deployer_) {
        try vm.envUint("PRIVATE_KEY") returns (uint256 privateKey) {
            return vm.addr(privateKey);
        } catch {
            return vm.envAddress("DEPLOYER");
        }
    }

    function _currentDeployerNonce(address deployer_) internal view returns (uint256) {
        return vm.getNonce(deployer_);
    }

    function _previewNonce(address deployer_) internal view returns (uint256 nonce_) {
        try vm.envUint("DEPLOYER_NONCE") returns (uint256 configuredNonce) {
            return configuredNonce;
        } catch {
            return vm.getNonce(deployer_);
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

    // ── Logging ────────────────────────────────────────────────────────────────────────

    function _logDeploymentPlan(address deployer_, uint256 startingNonce_, bytes32 salt_) internal pure {
        console2.log("Deployer:", deployer_);
        console2.log("Starting nonce:", startingNonce_);
        console2.logBytes32(salt_);
    }

    function _logAddresses(DeploymentAddresses memory d_) internal pure {
        console2.log("SafeSingleton:             ", d_.safeSingleton);
        console2.log("SafeProxyFactory:          ", d_.safeProxyFactory);
        console2.log("PENSafeBootstrap:          ", d_.safeBootstrap);
        console2.log("Safe:                      ", d_.safe);
        console2.log("SeatToken:                 ", d_.seatToken);
        console2.log("PrincipalManager:          ", d_.principalManager);
        console2.log("BondingTranche:            ", d_.bondingTranche);
        console2.log("SeatVotingStrategy:        ", d_.seatVotingStrategy);
        console2.log("PENTxAuthenticator:        ", d_.penTxAuthenticator);
        console2.log("Space:                     ", d_.space);
        console2.log("ExecutionStrategy:         ", d_.executionStrategy);
        console2.log("TimelockExecutionStrategy: ", d_.timelockExecutionStrategy);
    }

    function _writeDeploymentArtifact(DeploymentAddresses memory d_) internal {
        string memory json = string.concat(
            "{\n",
            '  "safeSingleton": "',             vm.toString(d_.safeSingleton),             '",\n',
            '  "safeProxyFactory": "',           vm.toString(d_.safeProxyFactory),           '",\n',
            '  "safeBootstrap": "',              vm.toString(d_.safeBootstrap),              '",\n',
            '  "safe": "',                       vm.toString(d_.safe),                       '",\n',
            '  "seatToken": "',                  vm.toString(d_.seatToken),                  '",\n',
            '  "principalManager": "',           vm.toString(d_.principalManager),           '",\n',
            '  "bondingTranche": "',             vm.toString(d_.bondingTranche),             '",\n',
            '  "seatVotingStrategy": "',         vm.toString(d_.seatVotingStrategy),         '",\n',
            '  "penTxAuthenticator": "',         vm.toString(d_.penTxAuthenticator),         '",\n',
            '  "space": "',                      vm.toString(d_.space),                      '",\n',
            '  "executionStrategy": "',          vm.toString(d_.executionStrategy),          '",\n',
            '  "timelockExecutionStrategy": "',  vm.toString(d_.timelockExecutionStrategy),  '"\n',
            "}"
        );

        string memory dir = "deployments";
        vm.createDir(dir, true);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeFile(path, json);
        console2.log("Deployment artifact written to:", path);
    }

    // ── Env helpers ────────────────────────────────────────────────────────────────────

    function _envOrZeroAddress(string memory key) internal view returns (address value) {
        try vm.envAddress(key) returns (address parsed) {
            return parsed;
        } catch {
            return address(0);
        }
    }

    function _envBoolOrFalse(string memory key) internal view returns (bool) {
        try vm.envBool(key) returns (bool v) {
            return v;
        } catch {
            return false;
        }
    }

    // ── Gas estimation ─────────────────────────────────────────────────────────────────

    /// @notice Reverts with a clear error if `deployer_` cannot cover the deployment.
    /// @dev Estimates gas by simulating the full deployment from the script's own context (constructor work
    ///      is independent of the caller, so the gas reading is representative). Multiplies by a buffered
    ///      gas price and compares with the deployer's balance.
    function _checkDeployerFunds(address deployer_, bytes32 salt_, DeploymentConfig memory config_)
        internal
        returns (uint256 estimatedGas, uint256 requiredWei)
    {
        estimatedGas = _estimateDeploymentGas(salt_, config_);

        uint256 bufferBps = _resolveGasBufferBps();
        uint256 bufferedGas = (estimatedGas * bufferBps) / _BPS_DENOMINATOR;
        uint256 gasPrice = _resolveGasPrice();
        requiredWei = bufferedGas * gasPrice;
        uint256 availableWei = deployer_.balance;

        console2.log("Estimated gas (raw):", estimatedGas);
        console2.log("Estimated gas (buffered):", bufferedGas);
        console2.log("Gas price (wei):", gasPrice);
        console2.log("Required (wei):", requiredWei);
        console2.log("Deployer balance (wei):", availableWei);

        if (availableWei < requiredWei) revert InsufficientDeployerBalance(requiredWei, availableWei);
    }

    function _estimateDeploymentGas(bytes32 salt_, DeploymentConfig memory config_) internal returns (uint256 gasUsed) {
        // Run a dry simulation from a deterministic synthetic deployer. Constructor work is independent
        // of the caller, so the gas reading is representative of the real deployment.
        uint256 simulatedKey = uint256(keccak256("PEN_GAS_PREVIEW"));
        address simulatedDeployer = vm.addr(simulatedKey);
        uint256 simulatedNonce = vm.getNonce(simulatedDeployer);
        DeploymentAddresses memory expected = previewDeployment(simulatedDeployer, simulatedNonce, salt_, config_);

        vm.startBroadcast(simulatedKey);
        uint256 gasBefore = gasleft();
        _deploySystem(expected, salt_, config_, simulatedDeployer);
        unchecked {
            gasUsed = gasBefore - gasleft();
        }
        vm.stopBroadcast();
    }

    function _resolveGasPrice() internal view returns (uint256 gasPrice) {
        try vm.envUint("GAS_PRICE_WEI") returns (uint256 envPrice) {
            return envPrice;
        } catch {
            gasPrice = tx.gasprice;
            if (gasPrice == 0) gasPrice = block.basefee;
        }
    }

    function _resolveGasBufferBps() internal view returns (uint256) {
        try vm.envUint("GAS_BUFFER_BPS") returns (uint256 envBps) {
            return envBps;
        } catch {
            return _DEFAULT_GAS_BUFFER_BPS;
        }
    }
}
