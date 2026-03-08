// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockPredictionToken
 * @notice A simple ERC-1155 token to simulate Polymarket conditional tokens.
 */
contract MockPredictionToken is ERC1155, Ownable {
    constructor(
        address initialOwner
    )
        ERC1155("https://mock.polymarket.com/token/{id}.json")
        Ownable(initialOwner)
    {}

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external onlyOwner {
        _mint(to, id, amount, data);
    }

    /**
     * @notice Public faucet for testing
     * @param id The conditionId (token type) to mint
     * @param amount The amount to mint
     */
    function faucet(uint256 id, uint256 amount) external {
        _mint(msg.sender, id, amount, "");
    }

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external onlyOwner {
        _mintBatch(to, ids, amounts, data);
    }

    // ─── Wallet Simulation Compliance ───
    // Many browser wallets (e.g. MetaMask) blindly query name() and symbol()
    // during transaction simulation, even for ERC-1155s, and will throw big
    // red errors or revert the simulation if these don't exist.
    function name() external pure returns (string memory) {
        return "Polymarket Conditional Token (Mock)";
    }

    function symbol() external pure returns (string memory) {
        return "COND";
    }
}
