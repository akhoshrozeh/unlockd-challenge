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
    uint256 public totalTokensStaked;

    // equiv to `totalSupply`; sum of all token prices staked (duplicates included)
    uint256 public totalValueStaked;
    uint256 public rewardRate = 1;
    uint256 public lastUpdateTime;

    // L(t) is the totalValueStaked at time t
    // 1 / L(t) for [0,b]
    uint256 public rewardPerTokenStored;

    // 1 / L(t) for [0, a-1]
    mapping(address => uint256) userRewardPerTokenPaid;

    // equivalent to `balance` of user
    mapping(address => uint256) public userValueStaked;

    // rewards of user
    mapping(address => uint256) public rewards;

    // information about each collection
    mapping(address => Collection) public collections;

    // [tokenAddress][tokenId] = owner;
    mapping(address => mapping(uint256 => address)) public tokenToOwner;

    struct Collection {
        // initPrice should never be updated
        uint256 initPrice;
        uint256 currPrice;
        uint8 accepted;
        uint8 liquidated;
    }

    event Staked(
        address[] indexed tokenAddresses,
        uint256[] indexed tokenIds,
        address indexed caller
    );
    event Withdraw(
        address[] indexed tokenAddresses,
        uint256[] indexed tokenIds,
        address indexed caller
    );
    event Redeem(uint256 amount, address caller);
    event Liquidation(
        uint256 indexed newPrice,
        uint256 indexed oldPrice,
        address indexed collection
    );

    // * initialize the ERC20 contract
    constructor(address _rewardsToken) {
        rewardsToken = IRewardsToken(_rewardsToken);
    }

    modifier updateRewards(address account) {
        // update for msg.sender
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }

    // calculate 1 / L(t) for [0, b]
    function rewardPerToken() public view returns (uint256) {
        // no division by 0
        if (totalValueStaked == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
            (((block.timestamp - lastUpdateTime) * rewardRate * 1e18) /
                totalValueStaked);
    }

    // returns how many rewards 'account' has earned
    function earned(address account) public view returns (uint256) {
        return
            ((userValueStaked[account] *
                (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) +
            rewards[account];
    }

    // user must `approve` this contract to transfer tokens before staking
    function stake(
        address[] calldata tokenAddresses,
        uint256[] calldata tokenIds
    ) external updateRewards(msg.sender) {
        require(tokenIds.length == tokenAddresses.length, "bad length");
        require(tokenIds.length > 0, "must be > 0");

        // gas savings;
        uint256 _totalValueStaked = totalValueStaked;
        uint256 _userValueStaked = userValueStaked[msg.sender];

        for (uint256 i; i < tokenIds.length; i++) {
            // load collection stats
            Collection memory c = collections[tokenAddresses[i]];

            // verify accepted token w/ valid price
            require(c.accepted == 1, "not accepted collection");

            tokenToOwner[tokenAddresses[i]][tokenIds[i]] = msg.sender;

            _totalValueStaked += c.initPrice;
            _userValueStaked += c.initPrice;

            // transfer the token
            IERC721(tokenAddresses[i]).safeTransferFrom(
                msg.sender,
                address(this),
                tokenIds[i]
            );
        }

        // write to storage after all updates
        totalValueStaked = _totalValueStaked;
        userValueStaked[msg.sender] = _userValueStaked;
        totalTokensStaked += tokenIds.length;

        emit Staked(tokenAddresses, tokenIds, msg.sender);
    }

    // * unstaking
    // * transfers back tokens and adjust pool and user staked values
    function withdraw(
        address[] calldata tokenAddresses,
        uint256[] calldata tokenIds
    ) external updateRewards(msg.sender) {
        require(tokenIds.length == tokenAddresses.length, "bad length");
        require(tokenIds.length > 0, "must be > 0");

        // gas savings
        uint256 _totalValueStaked = totalValueStaked;
        uint256 _userValueStaked = userValueStaked[msg.sender];

        for (uint256 i; i < tokenAddresses.length; i++) {
            // verify caller is staker for all tokens
            require(
                tokenToOwner[tokenAddresses[i]][tokenIds[i]] == msg.sender,
                "not owner"
            );

            // load collection stats
            Collection memory c = collections[tokenAddresses[i]];

            // adjust weights for rewards
            _totalValueStaked -= c.initPrice;
            _userValueStaked -= c.initPrice;
            delete tokenToOwner[tokenAddresses[i]][tokenIds[i]];

            // transfer the token back
            IERC721(tokenAddresses[i]).safeTransferFrom(
                address(this),
                msg.sender,
                tokenIds[i]
            );
        }

        // write to storage after all updates
        totalValueStaked = _totalValueStaked;
        userValueStaked[msg.sender] = _userValueStaked;
        totalTokensStaked -= tokenAddresses.length;

        emit Withdraw(tokenAddresses, tokenIds, msg.sender);
    }

    // * user exchanges rewards to erc20 i.e. mints rewards
    function redeem() external nonReentrant updateRewards(msg.sender) {
        uint256 amount = rewards[msg.sender];
        require(amount > 0, "no rewards");
        rewards[msg.sender] = 0;
        rewardsToken.mint(msg.sender, amount);

        emit Redeem(amount, msg.sender);
    }

    // * ONLYOWNER FUNCTIONS
    function createCollection(
        address token,
        uint256 price,
        uint8 accepted
    ) public onlyOwner {
        require(price > 0, "price must be > 0");
        require(collections[token].initPrice == 0, "coll already created");
        Collection memory c = Collection(price, price, accepted, 0);
        collections[token] = c;
    }

    // 0: dont accept
    // 1: accept
    function setCollectionAcceptance(address token, uint8 val)
        public
        onlyOwner
    {
        require(val == 1 || val == 0, "Bad `val`");
        collections[token].accepted = val;
    }

    function setCurrCollectionPrice(address token, uint256 newPrice)
        public
        onlyOwner
    {
        Collection memory c = collections[token];

        // more than 50% decrease and not liquidated already, emit liquiad
        if (c.liquidated == 0 && newPrice <= c.initPrice / 2) {
            emit Liquidation(newPrice, c.initPrice, token);
        }

        collections[token].currPrice = newPrice;
        collections[token].liquidated = 1;
    }

    // * VIEW FUNCTIONS
    function tokenStaker(address token, uint256 tokenId)
        public
        view
        returns (address)
    {
        return tokenToOwner[token][tokenId];
    }
}
