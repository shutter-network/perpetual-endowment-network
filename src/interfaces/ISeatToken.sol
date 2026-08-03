// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Custom (non-ERC20) surface of the PEN seat token. Use IERC20 separately for standard ERC-20 calls.
interface ISeatToken {
    function supplyCap() external view returns (uint256);

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function isInactive(address account) external view returns (bool);

    // ── Space binding (set-once bootstrap) ──────────────────────────────────────

    function space() external view returns (address);
    function spaceLocked() external view returns (bool);
    function bootstrap() external view returns (address);
    function expectedOwner() external view returns (address);
    function setSpace(address space_) external;

    // ── Activity refresh (permissionless; verified against Space.voteRegistry) ──

    function refreshActivity(address voter, uint256 proposalId) external;
    function refreshActivityForProposal(address author, uint256 proposalId) external;
    function refreshActivityForProposalVoters(uint256 proposalId, address[] calldata voters) external;
    function refreshActivityBatch(address[] calldata voters, uint256[] calldata proposalIds) external;
}
