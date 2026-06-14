// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Authenticator} from "@snapshot-x/authenticators/Authenticator.sol";
import {Choice, IndexedStrategy, Strategy} from "@snapshot-x/types.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ISeatToken} from "../interfaces/ISeatToken.sol";

/// @notice PENTxAuthenticator that records seat activity after a successful authenticated call.
/// @dev Holds `ACTIVITY_ROLE` on the seat token. Skips activity recording for zero-balance actors
///      to avoid reverting on SeatToken._recordActivity's NotSeatHolder check.
contract PENTxAuthenticator is Authenticator {
    error InvalidFunctionSelector();
    error InvalidMessageSender();
    error InvalidTarget();

    ISeatToken public immutable seat;
    address public immutable space;

    constructor(ISeatToken seat_, address space_) {
        seat = seat_;
        space = space_;
    }

    /// @notice Authenticates the caller, forwards the call to the Space, then records activity.
    function authenticate(address target, bytes4 functionSelector, bytes calldata data) external {
        if (target != space) revert InvalidTarget();
        address actor = _extractActor(functionSelector, data);
        if (actor != msg.sender) revert InvalidMessageSender();

        _call(target, functionSelector, data); // reverts on Space rejection; activity is not recorded

        if (IERC20(address(seat)).balanceOf(actor) > 0) {
            seat.recordActivity(actor);
        }
    }

    /// @dev Decodes the first address (voter/author) from calldata for each supported selector.
    function _extractActor(bytes4 selector, bytes calldata data) internal pure returns (address actor) {
        if (selector == PROPOSE_SELECTOR) {
            (actor,,,) = abi.decode(data, (address, string, Strategy, bytes));
        } else if (selector == VOTE_SELECTOR) {
            (actor,,,) = abi.decode(data, (address, uint256, Choice, IndexedStrategy[]));
        } else if (selector == UPDATE_PROPOSAL_SELECTOR) {
            (actor,,,) = abi.decode(data, (address, uint256, Strategy, string));
        } else {
            revert InvalidFunctionSelector();
        }
    }
}
