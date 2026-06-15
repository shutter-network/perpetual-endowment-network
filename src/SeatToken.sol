// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {Nonces} from "openzeppelin-contracts/contracts/utils/Nonces.sol";

import {ISeatToken} from "./interfaces/ISeatToken.sol";

contract SeatToken is ISeatToken, ERC20, ERC20Votes, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant ACTIVITY_ROLE = keccak256("ACTIVITY_ROLE");

    error ApprovalsDisabled();
    error InvalidAdmin(address admin);
    error InvalidInactivityPeriod();
    error InvalidSupplyCap(uint256 supplyCap);
    error NonSelfDelegation(address account, address delegatee);
    error NotSeatHolder(address account);
    error TransfersDisabled();

    uint256 public immutable override supplyCap;
    uint48 public immutable inactivityPeriod;

    mapping(address account => uint48) public lastActivityAt;

    event ActivityRecorded(address indexed account, uint48 timestamp);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supplyCap_,
        uint48 inactivityPeriod_,
        address admin_,
        address minter_,
        address burner_,
        address activityUpdater_
    ) ERC20(name_, symbol_) EIP712(name_, "1") {
        if (admin_ == address(0)) revert InvalidAdmin(admin_);
        // `uint208` upper bound is the ERC20Votes `_maxSupply()` ceiling — see
        // https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#ERC20Votes-_maxSupply--
        if (supplyCap_ == 0 || supplyCap_ > type(uint208).max) revert InvalidSupplyCap(supplyCap_);
        if (inactivityPeriod_ == 0) revert InvalidInactivityPeriod();

        supplyCap = supplyCap_;
        inactivityPeriod = inactivityPeriod_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantOptionalRole(MINTER_ROLE, minter_);
        _grantOptionalRole(BURNER_ROLE, burner_);
        _grantOptionalRole(ACTIVITY_ROLE, activityUpdater_);
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

    function recordActivity(address account) external override onlyRole(ACTIVITY_ROLE) {
        _recordActivity(account);
    }

    function recordActivityBatch(address[] calldata accounts) external onlyRole(ACTIVITY_ROLE) {
        uint256 length = accounts.length;
        for (uint256 i; i < length; ++i) {
            _recordActivity(accounts[i]);
        }
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

    function _recordActivity(address account) internal {
        if (balanceOf(account) == 0) revert NotSeatHolder(account);
        _setActivityTimestamp(account, uint48(block.timestamp));
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
