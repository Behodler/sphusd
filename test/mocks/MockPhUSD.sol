// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockPhUSD
/// @notice Reproduces FlaxToken (flax-token-v2) semantics: versioned, owner-granted mint
///         permission and an allowance-based `burn(holder, amount)`.
contract MockPhUSD is ERC20, Ownable {
    struct MinterInfo {
        bool canMint;
        uint256 mintVersion;
    }

    uint256 public mintVersion;
    mapping(address => MinterInfo) private _authorizedMinters;

    constructor() ERC20("Phoenix USD", "phUSD") Ownable(msg.sender) {}

    function setMinter(address minter, bool canMint) external onlyOwner {
        _authorizedMinters[minter] = MinterInfo({canMint: canMint, mintVersion: mintVersion});
    }

    function mint(address recipient, uint256 amount) external {
        MinterInfo memory info = _authorizedMinters[msg.sender];
        require(info.canMint, "phUSD: caller is not authorized to mint");
        require(info.mintVersion == mintVersion, "phUSD: minter version is outdated");
        _mint(recipient, amount);
    }

    function burn(address holder, uint256 amount) external {
        _spendAllowance(holder, msg.sender, amount);
        _burn(holder, amount);
    }

    function revokeAllMintPrivileges() external onlyOwner {
        mintVersion++;
    }

    function authorizedMinters(address minter) external view returns (MinterInfo memory) {
        return _authorizedMinters[minter];
    }
}
