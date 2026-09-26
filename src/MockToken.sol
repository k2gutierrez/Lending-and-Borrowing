// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title MockToken
 * @author Carlos Gutiérrez
 * @notice ERC20 token for testing the lending protocol
 */
contract MockToken is ERC20, Ownable {

    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_, uint256 initialSupply) ERC20(name, symbol) Ownable(msg.sender) {
        _decimals = decimals_;
        _mint(msg.sender, initialSupply);
    }

    /**
     * @dev Mint new tokens (Only owner)
     * @param to address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Burn tokens from caller
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Get the number of decimals
     * @return uint8 number of decimals
     */
    function decimals() public view virtual override returns(uint8) {
        return _decimals;
    }

}
