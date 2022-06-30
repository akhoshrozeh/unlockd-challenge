// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Botz is ERC20, Ownable {

    address staking;


    constructor()
    ERC20("RewardsToken", "RewardsToken")
    {
    }

    modifier onlyStaking() {
        require(msg.sender == staking, "not staking contract");
        _;
    }

    function setStakingAddress(address _staking) public onlyOwner {
        staking = _staking;
    }

    // only to be called by staking contract
    function mint(address account, uint amount) public onlyStaking {
        _mint(account, amount);
    }

}


