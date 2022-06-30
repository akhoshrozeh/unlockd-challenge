const { ethers, waffle} = require("hardhat");
const { expect } = require('chai');
const chai = require('chai');
const provider = waffle.provider;

// note: the owner of contract is the deployer. however, we want the only account to be OWNER_ROLE is the gnosis safe contract account

describe('Basic Functionalities\n  *********************\n', async function() {
    before('get factories', async function () {
        this.accounts = await hre.ethers.getSigners();

        // deploy 2 nft contracts, stored in `this.nfts`
        console.log("Creating 2 NFT contracts...")
        this.nftFactory = await hre.ethers.getContractFactory('NFT')
        this.nft = await this.nftFactory.deploy();
        await this.nft.deployed();

        this.nft2 = await this.nftFactory.deploy();
        await this.nft2.deployed();

        // deploy rewards token
        console.log('Creating RewardsToken contract...');
        this.erc20Factory = await hre.ethers.getContractFactory("RewardsToken");
        this.erc20 = await this.erc20Factory.deploy();
        await this.erc20.deployed();

        console.log('Creating Staking contract...')
        // deploy staking contract
        this.stakingFactory = await hre.ethers.getContractFactory("Staking");
        this.staking = await this.stakingFactory.deploy(this.erc20.address);
        await this.staking.deployed();

        // set staking address as authorized minter in our RewardsToken contract
        await this.erc20.connect(this.accounts[0]).setStakingAddress(this.staking.address); 
        
    });


    it('Minting NFTs to accounts...', async function () {
        // give 3 accounts 10 nfts each, from both nft contracts
        for(let i = 0; i < 3; i++) {
            await this.nft.connect(this.accounts[i]).mint(this.accounts[i].address, 10);
        }

        for(let i = 0; i < 3; i++) {
            await this.nft2.connect(this.accounts[i]).mint(this.accounts[i].address, 10);
        }

        expect(await this.nft.totalSupply()).to.equal(30);
    });

    it('Staking contract is IERC721Receiver compatible', async function () {
      await expect(this.staking.onERC721Received(this.staking.address, this.staking.address, 1, "0x4554480000000000000000000000000000000000000000000000000000000000")).to.not.be.reverted;
    })

    it('Staking can accept multiple NFT collections', async function () {
        // accounts approve staking contact first
        for(let i = 0; i < 3; i++) {
            await this.nft.connect(this.accounts[i]).setApprovalForAll(this.staking.address, true);
        }

        // staking doesnt accept this collection
        await expect(this.staking.stake([this.nft.address], [1])).to.be.revertedWith("not accepted collection")

        // Let staking contract accept both nft collections now (onlyOwner can do this)
        await this.staking.connect(this.accounts[0]).createCollection(this.nft.address, ethers.utils.parseEther("1.0"), 1);
        await this.staking.connect(this.accounts[0]).createCollection(this.nft2.address, ethers.utils.parseEther("1.0"), 1);
    })
    
    it('Correct rewards generated for stakers', async function () {
        let ts = 2000000000;
        let oneDay = 86400;
        await ethers.provider.send("evm_mine", [ts]);

        const tx = await this.staking.connect(this.accounts[0]).stake([this.nft.address], [1]);

        // Wait for one block confirmation. The transaction has been mined at this point.
        const receipt = await tx.wait();
        
        // Get the events
        const events = receipt?.events // # => Event[] | undefined

        // * uncomment this to see the Stake event emitted
        // console.log(events);
       
        // fast forward a day
        await ethers.provider.send("evm_mine", [ts + oneDay + 1]);
        
        // only 1 staker, so his rewards are 1 per sec
        expect(await this.staking.earned(this.accounts[0].address)).to.equal(86400);
        
        // have another staker stake
        await this.staking.connect(this.accounts[1]).stake([this.nft.address], [15]);
        
        // wait another day
        await ethers.provider.send("evm_mine", [ts + 2 * oneDay]);

        // now since they each own 50% of the pools value, they get 0.5 sec per day 
        expect(await this.staking.earned(this.accounts[0].address)).to.equal(129600);
        expect(await this.staking.earned(this.accounts[1].address)).to.be.equal(43199); // since 1 sec less than day    
    });


    it('Liquidation event emitted', async function () {
        const tx = await this.staking.connect(this.accounts[0]).setCurrCollectionPrice(this.nft.address, ethers.utils.parseEther("0.4"));
         // Wait for one block confirmation. The transaction has been mined at this point.
         const receipt = await tx.wait();
        
         // Get the events
         const events = receipt?.events // # => Event[] | undefined
 
         // * uncomment this to see the Liquidation event emitted
        //  console.log(events);
    })

    it('Withdraw event emitted when tokens unstaked', async function () {
        const tx = await this.staking.connect(this.accounts[0]).withdraw([this.nft.address], [1]);
         // Wait for one block confirmation. The transaction has been mined at this point.
         const receipt = await tx.wait();
        
         // Get the events
         const events = receipt?.events // # => Event[] | undefined
 
         // * uncomment this to see the Withdraw event emitted
        //  console.log(events);
    })

    it('Redeem event emitted when rewards are minted as ERC20s', async function () {
        let rewards =  await this.staking.earned(this.accounts[0].address);
        console.log("Earned: ", rewards);

        // user has no erc20s yet
        expect(await this.erc20.balanceOf(this.accounts[0].address)).to.equal(0);
        
        const tx = await this.staking.connect(this.accounts[0]).redeem();

        expect(await this.erc20.balanceOf(this.accounts[0].address)).to.equal(rewards);
        expect(await this.staking.earned(this.accounts[0].address)).to.equal(0);

    
         // Wait for one block confirmation. The transaction has been mined at this point.
         const receipt = await tx.wait();
        
         // Get the events
         const events = receipt?.events // # => Event[] | undefined
 
         // * uncomment this to see the Redeem event emitted
        //  console.log(events);
    });





});