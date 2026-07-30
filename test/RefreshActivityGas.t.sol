// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {console2} from "forge-std/console2.sol";

import {Safe} from "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import {SafeProxyFactory} from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import {Enum} from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

import {SeatToken} from "../src/SeatToken.sol";
import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {PENSafeBootstrap} from "../src/deployment/PENSafeBootstrap.sol";

import {PENBootstrapHelper} from "../script/BootstrapPEN.s.sol";

import {ProxyFactory} from "@snapshot-x/ProxyFactory.sol";
import {Space} from "@snapshot-x/Space.sol";
import {AvatarExecutionStrategy} from "@snapshot-x/execution-strategies/AvatarExecutionStrategy.sol";
import {EthTxAuthenticator} from "@snapshot-x/authenticators/EthTxAuthenticator.sol";
import {OZVotesVotingStrategy} from "@snapshot-x/voting-strategies/OZVotesVotingStrategy.sol";
import {Choice, IndexedStrategy, Strategy, MetaTransaction, InitializeCalldata} from "@snapshot-x/types.sol";

import {StubProposalValidation} from "./helpers/StubProposalValidation.sol";
import {SpaceInit} from "./helpers/SpaceInit.sol";

// Minimal Space call surface used here (kept local for the same source-unit-id reason
// noted in SpaceInit.sol).
interface ISpaceExec {
    function nextProposalId() external view returns (uint256);
}

/// @notice Batch-refresh gas benchmark (Slice 3). Measures the empirical envelope of
///         `refreshActivityForProposalVoters` and `refreshActivityBatch` against a real
///         sx-evm `Space` so keeper implementers can pick a safe batch size.
///
///         Run: `forge test --match-contract RefreshActivityGasTest -vv`
contract RefreshActivityGasTest is Test, PENBootstrapHelper {
    using stdStorage for StdStorage;

    // ── Governance parameters (loose bounds; benchmark cares about refresh gas, not vote logic)
    uint32 internal constant QUORUM = 1;
    uint32 internal constant VOTING_DELAY = 1;
    uint32 internal constant MIN_VOTING_DURATION = 1;
    uint32 internal constant MAX_VOTING_DURATION = 10;
    uint32 internal constant PROPOSER_THRESHOLD = 1;

    bytes4 internal constant PROPOSE_SELECTOR = bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));

    DeploymentAddresses internal sys;
    address internal space;
    address internal ozVotesStrategy;
    address internal ethTxAuthenticator;
    address internal proposer;
    MockUSDC internal paymentToken;

    uint256 internal proposalId;

    function setUp() public {
        // Same block/timestamp invariant as the integration harness so ERC5805FutureLookup
        // doesn't trip when `getPastVotes` is queried during propose.
        vm.roll(1);
        vm.warp(2);

        _deployTwoPhaseSystem();

        // A single proposer with a seat is enough for the benchmark: N mock voters are added
        // via `vm.store` below (no need to route each voter through Space.vote for a gas test
        // whose target is the *refresh* call, not the vote flow).
        proposer = makeAddr("proposer");
        SeatToken(sys.seatToken).mint(proposer, 1);
        _advance(1);

        // Real propose call so `proposals(id)` returns non-zero state. `_applyActivity` reads
        // maxEndBlockNumber; a genuine proposal makes that a real SLOAD.
        proposalId = _propose(proposer);

        // Advance past maxEndBlockNumber so `_applyActivity` runs the anti-farm branch
        // (proposal window closed → derived timestamp), matching the intended keeper flow
        // where refresh lands after voting has finished.
        _advance(MAX_VOTING_DURATION + VOTING_DELAY + 5);
    }

    // ── Benchmark: refreshActivityForProposalVoters ──────────────────────────────

    function test_gas_refreshActivityForProposalVoters_10() public {
        _runProposalVoters(10);
    }

    function test_gas_refreshActivityForProposalVoters_25() public {
        _runProposalVoters(25);
    }

    function test_gas_refreshActivityForProposalVoters_50() public {
        _runProposalVoters(50);
    }

    function test_gas_refreshActivityForProposalVoters_100() public {
        _runProposalVoters(100);
    }

    function test_gas_refreshActivityForProposalVoters_200() public {
        _runProposalVoters(200);
    }

    function test_gas_refreshActivityForProposalVoters_500() public {
        _runProposalVoters(500);
    }

    function test_gas_refreshActivityForProposalVoters_1000() public {
        _runProposalVoters(1000);
    }

    function _runProposalVoters(uint256 n) internal {
        address[] memory voters = _seedNVoters(n);

        SeatToken st = SeatToken(sys.seatToken);
        uint256 gasBefore = gasleft();
        st.refreshActivityForProposalVoters(proposalId, voters);
        uint256 gasUsed = gasBefore - gasleft();

        _logGas("refreshActivityForProposalVoters", n, gasUsed);
    }

    // ── Benchmark: refreshActivityBatch ──────────────────────────────────────────

    function test_gas_refreshActivityBatch_10() public {
        _runBatch(10);
    }

    function test_gas_refreshActivityBatch_25() public {
        _runBatch(25);
    }

    function test_gas_refreshActivityBatch_50() public {
        _runBatch(50);
    }

    function test_gas_refreshActivityBatch_100() public {
        _runBatch(100);
    }

    function test_gas_refreshActivityBatch_200() public {
        _runBatch(200);
    }

    function test_gas_refreshActivityBatch_500() public {
        _runBatch(500);
    }

    function test_gas_refreshActivityBatch_1000() public {
        _runBatch(1000);
    }

    function _runBatch(uint256 n) internal {
        address[] memory voters = _seedNVoters(n);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; // same proposal per entry — the per-entry cost i < n; ++i) {
            ids[i] = proposalId;
        }
        // still includes a `proposals(id)` SLOAD, so gas reflects the real per-entry price.

        SeatToken st = SeatToken(sys.seatToken);
        uint256 gasBefore = gasleft();
        st.refreshActivityBatch(voters, ids);
        uint256 gasUsed = gasBefore - gasleft();

        _logGas("refreshActivityBatch", n, gasUsed);
    }

    // ── Fixture: seed N voters with balance + a fake voteRegistry entry ──────────

    /// @dev Mints one seat to each of N synthetic voter addresses and sets
    ///      `voteRegistry[proposalId][voter] = 1` directly via storage. This is the operational
    ///      shortcut the impl doc endorses: the refresh call cares only about the mapping's
    ///      *value* (single SLOAD), not how the value got there. Casting N real votes through
    ///      the authenticator gives identical measurement at ~50x the setup cost.
    function _seedNVoters(uint256 n) internal returns (address[] memory voters) {
        voters = new address[](n);
        SeatToken st = SeatToken(sys.seatToken);
        for (uint256 i; i < n; ++i) {
            address voter = address(uint160(uint256(keccak256(abi.encodePacked("voter", i)))));
            voters[i] = voter;
            st.mint(voter, 1);
            stdstore.target(space).sig("voteRegistry(uint256,address)").with_key(proposalId).with_key(voter)
                .checked_write(uint256(1));
        }
    }

    function _logGas(string memory label, uint256 n, uint256 gasUsed) internal pure {
        uint256 perVoter = gasUsed / n;
        console2.log("---");
        console2.log(label);
        console2.log("  n         =", n);
        console2.log("  gas       =", gasUsed);
        console2.log("  gas/voter =", perVoter);
        // A conservative estimate of how many entries fit under an L1 (30M) block budget;
        // production keepers should cap at ~70% of this to leave slack for calldata + intrinsic gas.
        console2.log("  fits/30M  =", uint256(30_000_000) / (perVoter == 0 ? 1 : perVoter));
    }

    // ── Two-phase deploy (self-contained; the smallest slice of EndToEndProposal harness) ──

    function _deployTwoPhaseSystem() internal {
        ProxyFactory proxyFactory = new ProxyFactory();
        Space spaceImpl = new Space();
        AvatarExecutionStrategy avatarImpl =
            new AvatarExecutionStrategy(address(this), address(this), new address[](0), 1);
        StubProposalValidation propValidation = new StubProposalValidation();
        paymentToken = new MockUSDC();

        sys.safeSingleton = address(new Safe());
        sys.safeProxyFactory = address(new SafeProxyFactory());
        sys.safeBootstrap = address(new PENSafeBootstrap());
        ozVotesStrategy = address(new OZVotesVotingStrategy());
        ethTxAuthenticator = address(new EthTxAuthenticator());

        sys.executionStrategy = _computeProxyAddress(address(proxyFactory), address(avatarImpl), address(this), 0);
        sys.safe = _predictSafeAddress(sys, bytes32(0));

        proxyFactory.deployProxy(
            address(avatarImpl),
            abi.encodeCall(
                AvatarExecutionStrategy.setUp, (abi.encode(address(this), sys.safe, new address[](0), uint256(QUORUM)))
            ),
            0
        );

        sys.safe = address(
            SafeProxyFactory(sys.safeProxyFactory)
                .createProxyWithNonce(sys.safeSingleton, _safeInitializer(sys), uint256(0))
        );

        sys.seatToken = address(
            new SeatToken(
                "PEN Seat",
                "SEAT",
                1_000_000,
                uint48(365 days),
                address(this),
                address(0),
                address(0),
                address(this), // bootstrap
                sys.safe // expectedOwner
            )
        );
        sys.principalManager = address(
            new PrincipalManager(IERC20(address(paymentToken)), address(this), address(0), 0, IERC4626(address(0)))
        );

        {
            uint256[] memory bounds = new uint256[](1);
            bounds[0] = 1_000_000;
            uint256[] memory prices = new uint256[](1);
            prices[0] = 1;
            sys.bondingTranche = address(
                new BondingTranche(
                    SeatToken(sys.seatToken),
                    PrincipalManager(sys.principalManager),
                    0,
                    address(this),
                    address(this),
                    bounds,
                    prices
                )
            );
        }

        // Test-only role finalize: this contract mints/burns directly.
        SeatToken st = SeatToken(sys.seatToken);
        st.grantRole(st.MINTER_ROLE(), address(this));
        st.grantRole(st.BURNER_ROLE(), address(this));

        // Phase 2 simulacrum: deploy Space via ProxyFactory using the shared SpaceInit builder.
        _deploySpaceAndBootstrap(address(proxyFactory), address(spaceImpl), address(propValidation));
    }

    function _deploySpaceAndBootstrap(address pf, address si, address pv) internal {
        SpaceInit.Params memory params = SpaceInit.Params({
            owner: sys.safe,
            seatToken: sys.seatToken,
            ozVotesStrategy: ozVotesStrategy,
            proposalValidationStrategy: Strategy({
                addr: pv, params: abi.encode(uint256(PROPOSER_THRESHOLD), sys.seatToken)
            }),
            ethTxAuthenticator: ethTxAuthenticator,
            votingDelay: VOTING_DELAY,
            minVotingDuration: MIN_VOTING_DURATION,
            maxVotingDuration: MAX_VOTING_DURATION,
            metadataURI: "",
            daoURI: "",
            proposalValidationStrategyMetadataURI: "",
            votingStrategyMetadataURI: ""
        });
        InitializeCalldata memory init = SpaceInit.buildInitializeCalldata(params);
        ProxyFactory(pf).deployProxy(si, SpaceInit.encodeInitializeCall(init), 1);
        space = _computeProxyAddress(pf, si, address(this), 1);

        _bootstrapPEN(sys, space);
    }

    // ── Propose helper (single real proposal, no votes needed for the benchmark) ─

    function _defaultUserStrategies() internal pure returns (IndexedStrategy[] memory strats) {
        strats = new IndexedStrategy[](1);
        strats[0] = IndexedStrategy({index: 0, params: ""});
    }

    function _propose(address author) internal returns (uint256 id) {
        id = ISpaceExec(space).nextProposalId();
        MetaTransaction[] memory txs = new MetaTransaction[](1);
        txs[0] = MetaTransaction({to: address(0xdead), value: 0, data: "", operation: Enum.Operation.Call, salt: 0});
        bytes memory payload = abi.encode(txs);
        bytes memory data = abi.encode(
            author, "", Strategy({addr: sys.executionStrategy, params: payload}), abi.encode(_defaultUserStrategies())
        );
        vm.prank(author);
        EthTxAuthenticator(ethTxAuthenticator).authenticate(space, PROPOSE_SELECTOR, data);
    }

    function _advance(uint256 n) internal {
        vm.roll(block.number + n);
        vm.warp(block.timestamp + n);
    }
}
