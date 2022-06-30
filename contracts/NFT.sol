// SPDX-License-Identifier: Unlicensed
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";


contract NFT is ERC721 {

    uint public totalSupply;
    
    constructor() ERC721("NFT", "NFT") {

    }

    function mint(address to, uint amount) public {
        for(uint i; i < amount; i++) {
            _safeMint(to, totalSupply);
            totalSupply++;
        }
    }
}