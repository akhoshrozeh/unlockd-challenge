// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


interface IRewardsToken {
    function mint(address account, uint256 amount) external;
}

interface IERC721 {
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
}

contract Staking is ERC721Holder, Ownable, ReentrancyGuard {
    // The ERC20 rewards will be minted as
    IRewardsToken rewardsToken;

    // returns number of tokens staked
    uint public totalTokensStaked;

    // equiv to `totalSupply`; sum of all token prices staked (duplicates included)
    uint public totalValueStaked; 
    uint public rewardRate = 1;
    uint public lastUpdateTime;

    // L(t) is the totalValueStaked at time t
    // 1 / L(t) for [0,b]
    uint public rewardPerTokenStored;

    // 1 / L(t) for [0, a-1]
    mapping (address => uint) userRewardPerTokenPaid;

    // equivalent to `balance` of user
    mapping (address => uint) public userValueStaked; 

    // rewards of user
    mapping (address => uint) public rewards;

    struct Collection {
        // initPrice should never be updated
        uint initPrice;
        uint currPrice;
        uint8 accepted;
        uint8 liquidated;
    }

    mapping (address => Collection) public collections;

    // [tokenAddress][tokenId] = owner;
    mapping (address => mapping (uint => address)) public tokenToOwner;

    event Staked(address[] indexed tokenAddresses, uint[] indexed tokenIds, address indexed caller);
    event Withdraw(address[] indexed tokenAddresses, uint[] indexed tokenIds, address indexed caller);
    event Redeem(uint amount, address caller); 
    event Liquidation(uint indexed newPrice, uint indexed oldPrice, address indexed collection);



    // * initialize the ERC20 contract
    constructor(address _rewardsToken) {
        rewardsToken = IRewardsToken(_rewardsToken);
    }




    // calculate 1 / L(t) for [0, b]
    function rewardPerToken() public view returns (uint) {
        // no division by 0
        if (totalValueStaked == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((block.timestamp - lastUpdateTime) * rewardRate * 1e18) / totalValueStaked);
    }

    function earned(address account) public view returns (uint) {
        return
            ((userValueStaked[account] *
                (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) +
            rewards[account];
    }

    modifier updateRewards(address account) {
        // update for msg.sender
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;

    }

 
    // user must `approve` this contract to transfer tokens before staking
    function stake(address[] calldata tokenAddresses, uint[] calldata tokenIds) external updateRewards(msg.sender) {
        require(tokenIds.length == tokenAddresses.length, "bad length");
        require(tokenIds.length > 0, "must be > 0");

        // gas savings;
        uint _totalValueStaked = totalValueStaked;
        uint _userValueStaked = userValueStaked[msg.sender];

        for (uint i; i < tokenIds.length; i++) {
            // load collection stats
            Collection memory c = collections[tokenAddresses[i]];

            // verify accepted token w/ valid price
            require(c.accepted == 1, "not accepted collection");
            
            tokenToOwner[tokenAddresses[i]][tokenIds[i]] = msg.sender;

            _totalValueStaked += c.initPrice;
            _userValueStaked += c.initPrice;
            
            // transfer the token
            IERC721(tokenAddresses[i]).safeTransferFrom(msg.sender, address(this), tokenIds[i]);
        }

        // write to storage after all updates
        totalValueStaked = _totalValueStaked;
        userValueStaked[msg.sender] = _userValueStaked;
        totalTokensStaked += tokenIds.length;

        emit Staked(tokenAddresses, tokenIds, msg.sender);
    }

    // * unstaking
    // * transfers back tokens and adjust pool and user staked values
    function withdraw(address[] calldata tokenAddresses, uint[] calldata tokenIds) external updateRewards(msg.sender)  {
        require(tokenIds.length == tokenAddresses.length, "bad length");
        require(tokenIds.length > 0, "must be > 0");

        // gas savings
        uint _totalValueStaked = totalValueStaked;
        uint _userValueStaked = userValueStaked[msg.sender];

        for(uint i; i < tokenAddresses.length; i++) {
            // verify caller is staker for all tokens
            require(tokenToOwner[tokenAddresses[i]][tokenIds[i]] == msg.sender, "not owner");

            // load collection stats
            Collection memory c = collections[tokenAddresses[i]];

            // adjust weights for rewards
            _totalValueStaked -= c.initPrice;
            _userValueStaked -= c.initPrice;
            delete tokenToOwner[tokenAddresses[i]][tokenIds[i]];

            // transfer the token back
            IERC721(tokenAddresses[i]).safeTransferFrom(address(this), msg.sender, tokenIds[i]);
        }

        // write to storage after all updates
        totalValueStaked = _totalValueStaked;
        userValueStaked[msg.sender] = _userValueStaked;
        totalTokensStaked -= tokenAddresses.length;

        emit Withdraw(tokenAddresses, tokenIds, msg.sender);

    }



    // * user exchanges rewards to erc20 i.e. mints rewards
    function redeem() external nonReentrant updateRewards(msg.sender) {
        uint amount = rewards[msg.sender];
        require(amount > 0, "no rewards");
        rewards[msg.sender] = 0;
        rewardsToken.mint(msg.sender, amount);

        emit Redeem(amount, msg.sender);
    }

    



    // * ONLYOWNER FUNCTIONS

    function createCollection(address token, uint price, uint8 accepted) public onlyOwner {
        require(price > 0, "price must be > 0");
        require(collections[token].initPrice == 0, "coll already created");
        Collection memory c = Collection(price, price, accepted, 0);
        collections[token] = c;
    }
        
    // 0: dont accept
    // 1: accept
    function setCollectionAcceptance(address token, uint8 val) public onlyOwner {
        require(val == 1 || val == 0, "Bad `val`");
        collections[token].accepted = val;
    }

    function setCurrCollectionPrice(address token, uint newPrice) public onlyOwner {
        Collection memory c = collections[token];

        // more than 50% decrease and not liquidated already, emit liquiad 
        if (c.liquidated == 0 && newPrice <= c.initPrice / 2) {
            emit Liquidation(newPrice, c.initPrice, token );
        }

        collections[token].currPrice = newPrice;
        collections[token].liquidated = 1;
    }


    // * VIEW FUNCTIONS

    // * Front-end should call this function to show user what he has staked
    // * they can then select the Stakes to withdraw, and those tokenIds & addresses
    // * will be passed to `withdraw(uint[], address[])`
    // function getStakes(address user) public view returns (Stake[] memory) {
    //     return ownerToStakes[user];
    // }

    function tokenStaker(address token, uint tokenId) public returns (address) {
        return tokenToOwner[token][tokenId];
    }


}