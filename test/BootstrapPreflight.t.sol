// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {PENBootstrapHelper} from "../script/BootstrapPEN.s.sol";
import {Strategy} from "@snapshot-x/types.sol";

// ── Mocks implementing exactly the view surface the Phase-2 preflight reads ──────────────────
// The preflight's structural + config checks run BEFORE any state change in `_bootstrapPEN`
// (and standalone in `_assertGovernanceConfig`), so a Space/exec-strategy mock that answers
// these view calls is sufficient to exercise every revert path without a full sx-evm stack.

contract MockSpace {
    address public owner;
    mapping(address => uint256) public authenticators;
    address internal _vsAddr;
    bytes internal _vsParams;
    uint256 public activeVotingStrategies;
    uint8 public nextVotingStrategyIndex;
    address internal _pvAddr;
    bytes internal _pvParams;
    uint32 public votingDelay;
    uint32 public minVotingDuration;
    uint32 public maxVotingDuration;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address v) external {
        owner = v;
    }

    function setAuthenticator(address a, uint256 v) external {
        authenticators[a] = v;
    }

    function setVotingStrategy(address addr_, bytes calldata params_) external {
        _vsAddr = addr_;
        _vsParams = params_;
    }

    function setVotingStrategyMeta(uint256 active, uint8 next) external {
        activeVotingStrategies = active;
        nextVotingStrategyIndex = next;
    }

    function setProposalValidation(address addr_, bytes calldata params_) external {
        _pvAddr = addr_;
        _pvParams = params_;
    }

    function setWindow(uint32 delay, uint32 minDur, uint32 maxDur) external {
        votingDelay = delay;
        minVotingDuration = minDur;
        maxVotingDuration = maxDur;
    }

    function votingStrategies(uint8) external view returns (address, bytes memory) {
        return (_vsAddr, _vsParams);
    }

    function proposalValidationStrategy() external view returns (address, bytes memory) {
        return (_pvAddr, _pvParams);
    }
}

contract MockAvatarExec {
    address public owner;
    address public target;
    uint256 public quorum;
    mapping(address => uint256) public isSpaceEnabled;

    constructor(address owner_, address target_, uint256 quorum_) {
        owner = owner_;
        target = target_;
        quorum = quorum_;
    }

    function setOwner(address v) external {
        owner = v;
    }

    function setTarget(address v) external {
        target = v;
    }

    function setQuorum(uint256 v) external {
        quorum = v;
    }

    function setSpaceEnabled(address s, uint256 v) external {
        isSpaceEnabled[s] = v;
    }
}

contract MockTimelockExec {
    address public owner;
    uint256 public timelockDelay;
    uint256 public quorum;
    address public vetoGuardian;
    mapping(address => uint256) public isSpaceEnabled;

    constructor(address owner_, uint256 delay_, uint256 quorum_) {
        owner = owner_;
        timelockDelay = delay_;
        quorum = quorum_;
    }

    function setSpaceEnabled(address s, uint256 v) external {
        isSpaceEnabled[s] = v;
    }

    function setVetoGuardian(address v) external {
        vetoGuardian = v;
    }

    function setTimelockDelay(uint256 v) external {
        timelockDelay = v;
    }
}

/// @notice Unit tests for the Phase-2 governance-wiring preflight added for L-2: the finalize
///         must fail-closed BEFORE the irreversible swapOwner when the operator-supplied Space
///         or exec strategy does not match the env governance config, or is not linked to the
///         Space / does not control the Safe.
contract BootstrapPreflightTest is Test, PENBootstrapHelper {
    address internal constant SAFE = address(0x5AFE);
    address internal constant SEAT = address(0x5EA7);
    address internal constant AUTH = address(0xA07);
    address internal constant OZ = address(0x02);
    address internal constant PV = address(0x9B);

    uint32 internal constant VOTING_DELAY = 86_400;
    uint32 internal constant MIN_DUR = 259_200;
    uint32 internal constant MAX_DUR = 259_200;
    uint256 internal constant QUORUM = 10;
    uint256 internal constant THRESHOLD = 1;
    uint256 internal constant TIMELOCK_DELAY = 86_400;

    // External wrappers so `vm.expectRevert` intercepts reverts at a CALL boundary
    // (`expectRevert` does not catch reverts from internal JUMP-based calls).
    function callAssertGovernanceConfig(
        DeploymentAddresses memory d,
        address space,
        address exec,
        GovernanceConfig memory g
    ) external view {
        _assertGovernanceConfig(d, space, exec, g);
    }

    function callBootstrap(DeploymentAddresses memory d, address space, address exec, address deployer) external {
        _bootstrapPEN(d, space, exec, deployer);
    }

    function _deployed() internal pure returns (DeploymentAddresses memory d) {
        d.safe = SAFE;
        d.seatToken = SEAT;
    }

    function _gov(bool timelock) internal pure returns (GovernanceConfig memory g) {
        g.sxPropositionPowerValidation = PV;
        g.sxOzVotesStrategy = OZ;
        g.sxEthTxAuthenticator = AUTH;
        g.votingDelay = VOTING_DELAY;
        g.minVotingDuration = MIN_DUR;
        g.maxVotingDuration = MAX_DUR;
        g.avatarQuorum = QUORUM;
        g.proposerSeatThreshold = THRESHOLD;
        g.timelockEnabled = timelock;
        g.timelockDelay = timelock ? uint32(TIMELOCK_DELAY) : uint32(0);
    }

    function _validSpace() internal returns (MockSpace sp) {
        sp = new MockSpace(SAFE);
        sp.setAuthenticator(AUTH, 1);
        sp.setVotingStrategy(OZ, abi.encodePacked(SEAT));
        sp.setVotingStrategyMeta(1, 1);

        Strategy[] memory strats = new Strategy[](1);
        strats[0] = Strategy({addr: OZ, params: abi.encodePacked(SEAT)});
        sp.setProposalValidation(PV, abi.encode(THRESHOLD, strats));

        sp.setWindow(VOTING_DELAY, MIN_DUR, MAX_DUR);
    }

    function _validAvatar(address space) internal returns (MockAvatarExec ex) {
        ex = new MockAvatarExec(SAFE, SAFE, QUORUM);
        ex.setSpaceEnabled(space, 1);
    }

    function _validTimelock(address space) internal returns (MockTimelockExec ex) {
        ex = new MockTimelockExec(SAFE, TIMELOCK_DELAY, QUORUM);
        ex.setSpaceEnabled(space, 1);
    }

    // ── Happy paths ─────────────────────────────────────────────────────────────

    function test_preflight_passes_avatar() public {
        MockSpace sp = _validSpace();
        MockAvatarExec ex = _validAvatar(address(sp));
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    function test_preflight_passes_timelock() public {
        MockSpace sp = _validSpace();
        MockTimelockExec ex = _validTimelock(address(sp));
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(true));
    }

    // ── Structural link / control checks ─────────────────────────────────────────

    function test_preflight_reverts_execNotOwnedBySafe() public {
        MockSpace sp = _validSpace();
        MockAvatarExec ex = _validAvatar(address(sp));
        ex.setOwner(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.UnexpectedExecStrategyOwner.selector, address(0xBAD), SAFE)
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    function test_preflight_reverts_spaceNotEnabledOnExec() public {
        MockSpace sp = _validSpace();
        MockAvatarExec ex = _validAvatar(address(sp));
        ex.setSpaceEnabled(address(sp), 0); // exec strategy for a DIFFERENT space
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.ExecStrategySpaceNotEnabled.selector, address(ex), address(sp))
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    function test_preflight_reverts_avatarTargetNotSafe() public {
        MockSpace sp = _validSpace();
        MockAvatarExec ex = _validAvatar(address(sp));
        ex.setTarget(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.UnexpectedExecStrategyTarget.selector, address(0xBAD), SAFE)
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    function test_preflight_reverts_spaceNotOwnedBySafe() public {
        MockSpace sp = _validSpace();
        sp.setOwner(address(0xBAD));
        MockAvatarExec ex = _validAvatar(address(sp));
        vm.expectRevert(abi.encodeWithSelector(PENBootstrapHelper.UnexpectedSpaceOwner.selector, address(0xBAD), SAFE));
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    // ── Env-config mismatches (Space) ────────────────────────────────────────────

    function test_preflight_reverts_authenticatorMissing() public {
        MockSpace sp = _validSpace();
        sp.setAuthenticator(AUTH, 0);
        MockAvatarExec ex = _validAvatar(address(sp));
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.SpaceConfigMismatch.selector, bytes32("ethTxAuthenticator"))
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    function test_preflight_reverts_votingStrategyWrongToken() public {
        MockSpace sp = _validSpace();
        sp.setVotingStrategy(OZ, abi.encodePacked(address(0xDEAD))); // wrong token
        MockAvatarExec ex = _validAvatar(address(sp));
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.SpaceConfigMismatch.selector, bytes32("votingStrategyToken"))
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    function test_preflight_reverts_proposerThreshold() public {
        MockSpace sp = _validSpace();
        Strategy[] memory strats = new Strategy[](1);
        strats[0] = Strategy({addr: OZ, params: abi.encodePacked(SEAT)});
        sp.setProposalValidation(PV, abi.encode(uint256(999), strats)); // wrong threshold
        MockAvatarExec ex = _validAvatar(address(sp));
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.SpaceConfigMismatch.selector, bytes32("proposerThreshold"))
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    function test_preflight_reverts_votingDelay() public {
        MockSpace sp = _validSpace();
        sp.setWindow(1, MIN_DUR, MAX_DUR); // wrong votingDelay
        MockAvatarExec ex = _validAvatar(address(sp));
        vm.expectRevert(abi.encodeWithSelector(PENBootstrapHelper.SpaceConfigMismatch.selector, bytes32("votingDelay")));
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    // ── Env-config mismatches (exec strategy) ────────────────────────────────────

    function test_preflight_reverts_avatarQuorum() public {
        MockSpace sp = _validSpace();
        MockAvatarExec ex = _validAvatar(address(sp));
        ex.setQuorum(1); // wrong quorum
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.ExecStrategyConfigMismatch.selector, bytes32("quorum"))
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(false));
    }

    function test_preflight_reverts_timelockDelay() public {
        MockSpace sp = _validSpace();
        MockTimelockExec ex = _validTimelock(address(sp));
        ex.setTimelockDelay(1); // wrong delay
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.ExecStrategyConfigMismatch.selector, bytes32("timelockDelay"))
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(true));
    }

    function test_preflight_reverts_timelockVetoGuardianSet() public {
        MockSpace sp = _validSpace();
        MockTimelockExec ex = _validTimelock(address(sp));
        ex.setVetoGuardian(address(0xBAD)); // must be 0 per plan
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.ExecStrategyConfigMismatch.selector, bytes32("vetoGuardian"))
        );
        this.callAssertGovernanceConfig(_deployed(), address(sp), address(ex), _gov(true));
    }

    // ── The same structural guard fires inside `_bootstrapPEN` before any state change ──

    function test_bootstrap_reverts_onMispastedExec_beforeStateChange() public {
        MockSpace sp = _validSpace();
        MockAvatarExec ex = _validAvatar(address(sp));
        ex.setOwner(address(0xBAD)); // exec strategy not controlling this Safe
        vm.expectRevert(
            abi.encodeWithSelector(PENBootstrapHelper.UnexpectedExecStrategyOwner.selector, address(0xBAD), SAFE)
        );
        // seatToken/safe are never touched — the structural check reverts first.
        this.callBootstrap(_deployed(), address(sp), address(ex), address(this));
    }
}
