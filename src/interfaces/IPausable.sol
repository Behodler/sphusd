// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPausable
/// @notice Interface a contract implements to be registered with the global Pauser (PauserV2).
/// @dev Vendored verbatim in shape from `reflax-mint/pauser/src/interfaces/IPausable.sol`
///      (Behodler/pauser). PauserV2 calls `pause()` without try/catch, so implementers must make
///      `pause()` non-reverting for the authorised pauser, including when already paused.
interface IPausable {
    /// @notice Pause the contract. Reverts if the caller is not the authorised pauser.
    function pause() external;

    /// @notice Unpause the contract. Reverts if the caller is not authorised.
    function unpause() external;

    /// @notice The address authorised to pause this contract.
    /// @return The pauser address.
    function pauser() external view returns (address);
}
