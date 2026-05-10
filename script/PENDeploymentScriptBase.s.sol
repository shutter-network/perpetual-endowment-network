// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {RLP} from "openzeppelin-contracts/contracts/utils/RLP.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";
import {PENStrategyV1} from "../src/governance/PENStrategyV1.sol";
import {PENSafeBootstrap} from "../src/deployment/PENSafeBootstrap.sol";

import {IVotingTypes} from "decent-contracts/contracts/interfaces/decent/deployables/IVotingTypes.sol";
import {ModuleAzoriusV1} from "decent-contracts/contracts/deployables/modules/ModuleAzoriusV1.sol";
import {
    ProposerAdapterERC20V1
} from "decent-contracts/contracts/deployables/strategies/proposer-adapters/ProposerAdapterERC20V1.sol";
import {
    VoteTrackerERC20V1
} from "decent-contracts/contracts/deployables/strategies/vote-trackers/VoteTrackerERC20V1.sol";
import {
    VotingWeightERC20V1
} from "decent-contracts/contracts/deployables/strategies/voting-weight/VotingWeightERC20V1.sol";
import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import {SafeProxy} from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";

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
        uint32 votingPeriod;
        uint32 timelockPeriod;
        uint32 executionPeriod;
        uint256 quorumThreshold;
        uint256 basisNumerator;
        uint256 proposerThreshold;
        uint256 votingWeightPerToken;
        address lightAccountFactory;
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
        address strategy;
        address azorius;
        address votingWeight;
        address voteTracker;
        address proposerAdapter;
    }

    function previewDeployment(
        address deployer_,
        uint256 startingNonce_,
        bytes32 salt_,
        DeploymentConfig memory config_
    ) public pure returns (DeploymentAddresses memory predicted_) {
        uint256 nextNonce = startingNonce_;

        predicted_.safeSingleton = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.safeProxyFactory = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.safeBootstrap = _computeCreateAddress(deployer_, nextNonce++);

        nextNonce += 5;

        predicted_.strategy = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.votingWeight = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.voteTracker = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.proposerAdapter = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.azorius = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.seatToken = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.principalManager = _computeCreateAddress(deployer_, nextNonce++);
        predicted_.bondingTranche = _computeCreateAddress(deployer_, nextNonce++);

        predicted_.safe = _predictSafeAddress(predicted_, salt_);
    }

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

        (
            deployed_.strategy,
            deployed_.votingWeight,
            deployed_.voteTracker,
            deployed_.proposerAdapter,
            deployed_.azorius
        ) = _deployGovernanceClones(expected_);

        (deployed_.seatToken, deployed_.principalManager, deployed_.bondingTranche) =
            _deployCoreContracts(expected_, config_, bootstrapAuthority_);

        deployed_.safe = address(
            SafeProxyFactory(deployed_.safeProxyFactory)
                .createProxyWithNonce(deployed_.safeSingleton, _safeInitializer(expected_), uint256(salt_))
        );
        _assertDeployedAddress("SAFE", expected_.safe, deployed_.safe);

        _initializeGovernance(expected_, config_);
        _finalizeAccess(expected_, bootstrapAuthority_);

        return expected_;
    }

    function _deployGovernanceClones(DeploymentAddresses memory expected_)
        internal
        returns (
            address strategy_,
            address votingWeight_,
            address voteTracker_,
            address proposerAdapter_,
            address azorius_
        )
    {
        address strategyImplementation = address(new PENStrategyV1());
        address votingWeightImplementation = address(new VotingWeightERC20V1());
        address voteTrackerImplementation = address(new VoteTrackerERC20V1());
        address proposerAdapterImplementation = address(new ProposerAdapterERC20V1());
        address azoriusImplementation = address(new ModuleAzoriusV1());

        strategy_ = Clones.clone(strategyImplementation);
        _assertDeployedAddress("STRATEGY", expected_.strategy, strategy_);

        votingWeight_ = Clones.clone(votingWeightImplementation);
        _assertDeployedAddress("VOTING_WEIGHT", expected_.votingWeight, votingWeight_);

        voteTracker_ = Clones.clone(voteTrackerImplementation);
        _assertDeployedAddress("VOTE_TRACKER", expected_.voteTracker, voteTracker_);

        proposerAdapter_ = Clones.clone(proposerAdapterImplementation);
        _assertDeployedAddress("PROPOSER_ADAPTER", expected_.proposerAdapter, proposerAdapter_);

        azorius_ = Clones.clone(azoriusImplementation);
        _assertDeployedAddress("AZORIUS", expected_.azorius, azorius_);
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
                expected_.strategy
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

    function _initializeGovernance(DeploymentAddresses memory deployed_, DeploymentConfig memory config_) internal {
        ProposerAdapterERC20V1(deployed_.proposerAdapter)
            .initialize(deployed_.seatToken, config_.governance.proposerThreshold);

        address[] memory proposerAdapters = new address[](1);
        proposerAdapters[0] = deployed_.proposerAdapter;
        PENStrategyV1(deployed_.strategy)
            .initialize(
                config_.governance.votingPeriod,
                config_.governance.quorumThreshold,
                config_.governance.basisNumerator,
                proposerAdapters,
                config_.governance.lightAccountFactory
            );

        VotingWeightERC20V1(deployed_.votingWeight)
            .initialize(deployed_.seatToken, config_.governance.votingWeightPerToken);

        address[] memory authorizedCallers = new address[](1);
        authorizedCallers[0] = deployed_.strategy;
        VoteTrackerERC20V1(deployed_.voteTracker).initialize(authorizedCallers);

        ModuleAzoriusV1(deployed_.azorius)
            .initialize(
                deployed_.safe,
                deployed_.safe,
                deployed_.safe,
                deployed_.strategy,
                config_.governance.timelockPeriod,
                config_.governance.executionPeriod
            );

        IVotingTypes.VotingConfig[] memory votingConfigs = new IVotingTypes.VotingConfig[](1);
        votingConfigs[0] =
            IVotingTypes.VotingConfig({votingWeight: deployed_.votingWeight, voteTracker: deployed_.voteTracker});
        PENStrategyV1(deployed_.strategy).initialize2(deployed_.azorius, votingConfigs);
    }

    function _finalizeAccess(DeploymentAddresses memory deployed_, address bootstrapAuthority_) internal {
        SeatToken seatToken = SeatToken(deployed_.seatToken);
        PrincipalManager principalManager = PrincipalManager(deployed_.principalManager);
        BondingTranche bondingTranche = BondingTranche(deployed_.bondingTranche);

        seatToken.grantRole(seatToken.MINTER_ROLE(), deployed_.bondingTranche);
        seatToken.grantRole(seatToken.BURNER_ROLE(), deployed_.bondingTranche);
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

    function _safeInitializer(DeploymentAddresses memory predicted_) internal pure returns (bytes memory) {
        address[] memory owners = new address[](1);
        owners[0] = predicted_.azorius;

        bytes memory bootstrapData = abi.encodeCall(PENSafeBootstrap.setUp, (predicted_.azorius));

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

    function _computeCreateAddress(address deployer_, uint256 nonce_) internal pure returns (address) {
        bytes[] memory encoded = new bytes[](2);
        encoded[0] = RLP.encode(deployer_);
        encoded[1] = RLP.encode(nonce_);

        return address(uint160(uint256(keccak256(RLP.encode(encoded)))));
    }

    function _assertDeployedAddress(bytes32 component_, address expected_, address actual_) internal pure {
        if (expected_ != actual_) revert UnexpectedDeploymentAddress(component_, expected_, actual_);
    }
}

abstract contract PENDeploymentScriptBase is Script, PENDeploymentHelper {
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

        config.governance = GovernanceConfig({
            votingPeriod: uint32(vm.envUint("VOTING_PERIOD")),
            timelockPeriod: uint32(vm.envUint("TIMELOCK_PERIOD")),
            executionPeriod: uint32(vm.envUint("EXECUTION_PERIOD")),
            quorumThreshold: vm.envUint("QUORUM_THRESHOLD"),
            basisNumerator: vm.envUint("BASIS_NUMERATOR"),
            proposerThreshold: vm.envUint("PROPOSER_THRESHOLD"),
            votingWeightPerToken: vm.envUint("VOTING_WEIGHT_PER_TOKEN"),
            lightAccountFactory: _envOrZeroAddress("LIGHT_ACCOUNT_FACTORY")
        });
    }

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

    function _logDeploymentPlan(address deployer_, uint256 startingNonce_, bytes32 salt_) internal pure {
        console2.log("Deployer:", deployer_);
        console2.log("Starting nonce:", startingNonce_);
        console2.logBytes32(salt_);
    }

    function _logAddresses(DeploymentAddresses memory deployed_) internal pure {
        console2.log("SafeSingleton:", deployed_.safeSingleton);
        console2.log("SafeProxyFactory:", deployed_.safeProxyFactory);
        console2.log("PENSafeBootstrap:", deployed_.safeBootstrap);
        console2.log("Safe:", deployed_.safe);
        console2.log("SeatToken:", deployed_.seatToken);
        console2.log("PrincipalManager:", deployed_.principalManager);
        console2.log("BondingTranche:", deployed_.bondingTranche);
        console2.log("Strategy:", deployed_.strategy);
        console2.log("Azorius:", deployed_.azorius);
        console2.log("VotingWeight:", deployed_.votingWeight);
        console2.log("VoteTracker:", deployed_.voteTracker);
        console2.log("ProposerAdapter:", deployed_.proposerAdapter);
    }

    function _envOrZeroAddress(string memory key) internal view returns (address value) {
        try vm.envAddress(key) returns (address parsed) {
            return parsed;
        } catch {
            return address(0);
        }
    }
}
