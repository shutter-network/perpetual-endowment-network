// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVotingStrategy} from "@snapshot-x/interfaces/IVotingStrategy.sol";
import {IVotes} from "openzeppelin-contracts/contracts/governance/utils/IVotes.sol";

/// @notice Voting power = `IVotes.getPastVotes(voter, blockNumber)` on the configured seat token.
///
/// The Space passes `startBlockNumber` for votes (always in the past by the time voting opens)
/// and PropositionPower passes `block.number` (the current block) for proposal validation.
/// OZ v5 `getPastVotes` requires `timepoint < clock()`, so we cap to `block.number - 1` when
/// the received timepoint would otherwise trigger ERC5805FutureLookup.
contract SeatVotingStrategy is IVotingStrategy {
    /// @dev `params` encoding: abi.encode(address seatToken)
    function getVotingPower(
        uint32 blockNumber,
        address voter,
        bytes calldata params,
        bytes calldata /* userParams */
    ) external view override returns (uint256) {
        address seat = abi.decode(params, (address));
        uint256 safeTimepoint = (block.number > 0 && blockNumber >= block.number)
            ? block.number - 1
            : blockNumber;
        return IVotes(seat).getPastVotes(voter, safeTimepoint);
    }
}
