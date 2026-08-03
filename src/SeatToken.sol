// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {Nonces} from "openzeppelin-contracts/contracts/utils/Nonces.sol";

import {ISeatToken} from "./interfaces/ISeatToken.sol";
import {Proposal} from "@snapshot-x/types.sol";

interface ISpace {
    function owner() external view returns (address);
    function voteRegistry(uint256 proposalId, address voter) external view returns (uint256);
    function proposals(uint256 proposalId) external view returns (Proposal memory);
}

contract SeatToken is ISeatToken, ERC20, ERC20Votes, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    error ApprovalsDisabled();
    error InvalidAdmin(address admin);
    error InvalidInactivityPeriod();
    error InvalidSupplyCap(uint256 supplyCap);
    error NonSelfDelegation(address account, address delegatee);
    error InvalidBatchInput();
    error InvalidSpace();
    error NotBootstrap();
    error NotProposer(address author, uint256 proposalId);
    error NotSeatHolder(address account);
    error NotVoted(address voter, uint256 proposalId);
    error SpaceAlreadyLocked();
    error SpaceNotAContract();
    error SpaceNotSet();
    error UnexpectedSpaceOwner(address actual, address expected);
    error TransfersDisabled();

    /// @notice Average block time in seconds — used by `_applyActivity` to bound a late refresh
    ///         to (approximately) the vote-window-close timestamp of the referenced proposal.
    /// @dev Set for post-merge Ethereum mainnet. If PEN is ever redeployed on another chain,
    ///      edit this constant and recompile — the design deliberately does NOT expose a
    ///      runtime override (see `docs/future-refresh-activity.md` §"The block-time
    ///      approximation"). Reference values by chain:
    ///        - Ethereum mainnet (post-merge): 12
    ///        - Base / Optimism / Arbitrum: ~2
    ///        - Polygon PoS: ~2
    ///      The guardrail test `test_AvgBlockTimeMatchesMainnetAssumption` in
    ///      `test/SeatToken.t.sol` fails on any change so a redeploy on a different chain
    ///      must be a deliberate, coordinated edit.
    uint256 public constant AVG_BLOCK_TIME = 12;

    uint256 public immutable override supplyCap;
    uint48 public immutable inactivityPeriod;

    address public immutable expectedOwner;
    address public bootstrap;
    address public space;
    bool public spaceLocked;

    mapping(address account => uint48) public lastActivityAt;

    event ActivityRecorded(address indexed account, uint48 timestamp);
    event SpaceLocked(address indexed space);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supplyCap_,
        uint48 inactivityPeriod_,
        address admin_,
        address minter_,
        address burner_,
        address bootstrap_,
        address expectedOwner_
    ) ERC20(name_, symbol_) EIP712(name_, "1") {
        if (admin_ == address(0)) revert InvalidAdmin(admin_);
        // `uint208` upper bound is the ERC20Votes `_maxSupply()` ceiling — see
        // https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#ERC20Votes-_maxSupply--
        if (supplyCap_ == 0 || supplyCap_ > type(uint208).max) revert InvalidSupplyCap(supplyCap_);
        if (inactivityPeriod_ == 0) revert InvalidInactivityPeriod();

        supplyCap = supplyCap_;
        inactivityPeriod = inactivityPeriod_;
        bootstrap = bootstrap_;
        expectedOwner = expectedOwner_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantOptionalRole(MINTER_ROLE, minter_);
        _grantOptionalRole(BURNER_ROLE, burner_);
    }

    function decimals() public pure override returns (uint8) {
        return 0;
    }

    function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    function refreshActivity(address voter, uint256 proposalId) external {
        if (!spaceLocked) revert SpaceNotSet();
        if (balanceOf(voter) == 0) revert NotSeatHolder(voter);
        ISpace sp = ISpace(space);
        if (sp.voteRegistry(proposalId, voter) == 0) revert NotVoted(voter, proposalId);
        _applyActivity(voter, sp.proposals(proposalId).maxEndBlockNumber);
    }

    function refreshActivityForProposal(address author, uint256 proposalId) external {
        if (!spaceLocked) revert SpaceNotSet();
        if (balanceOf(author) == 0) revert NotSeatHolder(author);
        Proposal memory p = ISpace(space).proposals(proposalId);
        if (p.author != author) revert NotProposer(author, proposalId);
        _applyActivity(author, p.startBlockNumber);
    }

    /// @notice Refresh activity for many voters on the SAME proposal in one tx.
    /// @dev    Reads `proposals(proposalId).maxEndBlockNumber` once and reuses it for every
    ///         voter, so gas scales linearly with voter count and does not pay for a per-entry
    ///         proposal lookup. Entries failing the seatholder or voteRegistry check are
    ///         silently skipped so a single bad voter cannot unwind the whole batch.
    function refreshActivityForProposalVoters(uint256 proposalId, address[] calldata voters) external {
        if (!spaceLocked) revert SpaceNotSet();
        ISpace sp = ISpace(space);
        uint32 maxEndBlockNumber = sp.proposals(proposalId).maxEndBlockNumber;
        for (uint256 i; i < voters.length; ++i) {
            if (balanceOf(voters[i]) == 0) continue;
            if (sp.voteRegistry(proposalId, voters[i]) == 0) continue;
            _applyActivity(voters[i], maxEndBlockNumber);
        }
    }

    /// @notice Refresh activity across voter/proposal pairs. Use only when refreshing across
    ///         multiple proposals in one tx; for single-proposal batches, prefer
    ///         `refreshActivityForProposalVoters` (cheaper — one `proposals(id)` lookup).
    function refreshActivityBatch(address[] calldata voters, uint256[] calldata proposalIds) external {
        if (!spaceLocked) revert SpaceNotSet();
        if (voters.length != proposalIds.length) revert InvalidBatchInput();
        ISpace sp = ISpace(space);
        for (uint256 i; i < voters.length; ++i) {
            if (balanceOf(voters[i]) == 0) continue;
            if (sp.voteRegistry(proposalIds[i], voters[i]) == 0) continue;
            _applyActivity(voters[i], sp.proposals(proposalIds[i]).maxEndBlockNumber);
        }
    }

    /// @dev Sets activity to (approximately) the timestamp at `boundBlockNumber`, capped by
    ///      current block.timestamp. Never moves activity backward.
    function _applyActivity(address holder, uint32 boundBlockNumber) internal {
        uint256 ts;
        if (block.number <= boundBlockNumber) {
            ts = block.timestamp;
        } else {
            uint256 secondsSince = (block.number - boundBlockNumber) * AVG_BLOCK_TIME;
            ts = block.timestamp > secondsSince ? block.timestamp - secondsSince : 0;
        }
        if (uint48(ts) > lastActivityAt[holder]) {
            _setActivityTimestamp(holder, uint48(ts));
        }
    }

    function setSpace(address space_) external {
        // Order matters: check the locked flag before the bootstrap identity so a second
        // call after a successful setSpace surfaces `SpaceAlreadyLocked` (accurate) rather
        // than `NotBootstrap` (misleading — the slot is cleared, not revoked from a specific
        // address).
        if (spaceLocked) revert SpaceAlreadyLocked();
        if (msg.sender != bootstrap) revert NotBootstrap();
        if (space_ == address(0)) revert InvalidSpace();
        if (space_.code.length == 0) revert SpaceNotAContract();
        address actualOwner = ISpace(space_).owner();
        if (actualOwner != expectedOwner) revert UnexpectedSpaceOwner(actualOwner, expectedOwner);
        space = space_;
        spaceLocked = true;
        bootstrap = address(0);
        emit SpaceLocked(space_);
    }

    function isInactive(address account) public view override returns (bool) {
        uint256 balance = balanceOf(account);
        if (balance == 0) {
            return false;
        }

        uint48 lastActivity = lastActivityAt[account];
        if (lastActivity == 0) {
            return true;
        }

        return uint256(lastActivity) + inactivityPeriod <= block.timestamp;
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransfersDisabled();
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert ApprovalsDisabled();
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function nonces(address owner) public view override(Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function _maxSupply() internal view override returns (uint256) {
        return supplyCap;
    }

    function _delegate(address account, address delegatee) internal override {
        if (account != delegatee) revert NonSelfDelegation(account, delegatee);
        super._delegate(account, delegatee);
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) revert TransfersDisabled();

        super._update(from, to, amount);

        if (from == address(0)) {
            if (delegates(to) == address(0)) {
                super._delegate(to, to);
            }
            _setActivityTimestamp(to, uint48(block.timestamp));
        } else if (to == address(0) && balanceOf(from) == 0) {
            delete lastActivityAt[from];
        }
    }

    function _setActivityTimestamp(address account, uint48 timestamp) internal {
        lastActivityAt[account] = timestamp;
        emit ActivityRecorded(account, timestamp);
    }

    function _grantOptionalRole(bytes32 role, address account) internal {
        if (account == address(0)) {
            return;
        }

        _grantRole(role, account);
    }
}
