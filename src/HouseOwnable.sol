// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title HouseOwnable
/// @notice Two-step ownership for every Proof House contract. The owner is the curator. Renouncing is disabled so
///         a curated house can never be left without a curator.
abstract contract HouseOwnable is Ownable2Step {
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Disabled: ownership can only move through transferOwnership / acceptOwnership.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
