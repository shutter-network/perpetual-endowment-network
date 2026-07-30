// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strategy, InitializeCalldata} from "@snapshot-x/types.sol";

/// @notice Locally-declared Space initialize interface so `abi.encodeCall` can be resolved
///         against the same `InitializeCalldata` source-unit id we imported. `ISpaceActions.sol`
///         in sx-evm uses a bare `src/types.sol` import that yields a different id, so we can't
///         `abi.encodeCall(ISpaceActions.initialize, ...)` directly.
///         Remove once snapshot-labs/sx-evm switches to relative imports.
interface ISpace {
    function initialize(InitializeCalldata calldata input) external;
}

/// @notice Builder for the Space `InitializeCalldata` used at Phase-2 Space creation.
/// @dev    Kept as a library (internal pure) so both production tooling (Preview /
///         BootstrapPEN sanity docs) and the two-phase integration test harness share
///         one source of truth for what the operator submits to `snapshot.box`.
library SpaceInit {
    struct Params {
        address owner; // deployed Safe address — must match SeatToken.expectedOwner
        address seatToken; // params of the OZVotes voting strategy
        address ozVotesStrategy; // stock OZVotesVotingStrategy address
        Strategy proposalValidationStrategy; // caller supplies both addr and params bytes
        address ethTxAuthenticator; // stock EthTxAuthenticator address
        uint32 votingDelay;
        uint32 minVotingDuration;
        uint32 maxVotingDuration;
        string metadataURI;
        string daoURI;
        string proposalValidationStrategyMetadataURI;
        string votingStrategyMetadataURI;
    }

    /// @notice Construct the Space `InitializeCalldata` from PEN-shaped inputs.
    /// @dev    The stock `OZVotesVotingStrategy` decodes params via `address(bytes20(params))`,
    ///         i.e. `abi.encodePacked`, not `abi.encode`. `PropositionPower`-style validation
    ///         params are caller-encoded because production uses `(uint256, Strategy[])` while
    ///         the test `StubProposalValidation` uses `(uint256, address)`.
    function buildInitializeCalldata(Params memory p) internal pure returns (InitializeCalldata memory) {
        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy({addr: p.ozVotesStrategy, params: abi.encodePacked(p.seatToken)});

        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = p.votingStrategyMetadataURI;

        address[] memory authenticators = new address[](1);
        authenticators[0] = p.ethTxAuthenticator;

        return InitializeCalldata({
            owner: p.owner,
            votingDelay: p.votingDelay,
            minVotingDuration: p.minVotingDuration,
            maxVotingDuration: p.maxVotingDuration,
            proposalValidationStrategy: p.proposalValidationStrategy,
            proposalValidationStrategyMetadataURI: p.proposalValidationStrategyMetadataURI,
            daoURI: p.daoURI,
            metadataURI: p.metadataURI,
            votingStrategies: votingStrategies,
            votingStrategyMetadataURIs: votingStrategyMetadataURIs,
            authenticators: authenticators
        });
    }

    /// @notice Encode the initialize call that gets passed to `ProxyFactory.deployProxy`.
    function encodeInitializeCall(InitializeCalldata memory init) internal pure returns (bytes memory) {
        return abi.encodeCall(ISpace.initialize, (init));
    }
}
