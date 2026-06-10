// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVotes} from "openzeppelin-contracts/contracts/governance/utils/IVotes.sol";

// Minimal proposal validation for the integration test suite.
// Decodes params as (uint256 threshold, address seatToken) and returns true when
// IVotes.getPastVotes(author, block.number) >= threshold.
//
// Using block.number as the snapshot matches PropositionPower._validate behaviour.
// The invariant block.timestamp = block.number + 1 (maintained by _advance) ensures
// getPastVotes never hits ERC5805FutureLookup.
//
// This stub exists because PropositionPowerProposalValidationStrategy inherits
// PropositionPower which uses SXUtils via `using SXUtils for IndexedStrategy[]`.
// SXUtils.sol imports IndexedStrategy via a bare "src/types.sol" path, creating a
// different source unit ID than PropositionPower's relative "../types.sol" import.
// solc's type system sees two distinct IndexedStrategy types and rejects the `using`
// binding. The contextual remapping lib/sx-evm/:src/=lib/sx-evm/src/ does not resolve
// this conflict in practice, so the stub sidesteps the dependency entirely.
// TODO(upstream-fix): remove stub once snapshot-labs/sx-evm fixes bare "src/" imports.
contract StubProposalValidation {
    function validate(address author, bytes calldata params, bytes calldata /* userParams */)
        external
        view
        returns (bool)
    {
        (uint256 threshold, address seatToken) = abi.decode(params, (uint256, address));
        try IVotes(seatToken).getPastVotes(author, block.number > 0 ? block.number - 1 : 0) returns (uint256 power) {
            return power >= threshold;
        } catch {
            return threshold == 0;
        }
    }
}
