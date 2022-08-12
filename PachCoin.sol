//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract PachCoin is ERC20, ERC20Burnable {
    address owner;

    constructor(string memory name, string memory symbol, uint256 totalSupply) ERC20(name, symbol) 
    {
        _mint(_msgSender(), totalSupply);
        owner = _msgSender();
    }
}