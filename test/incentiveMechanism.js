const {
  BN,
  expectRevert,
  ether,
  expectEvent,
  balance,
  time,
} = require("@openzeppelin/test-helpers");

const PoolDeposits = artifacts.require("PoolDeposits");
const NoLossDao = artifacts.require("NoLossDao_v0");
const AaveLendingPool = artifacts.require("AaveLendingPool");
const LendingPoolAddressProvider = artifacts.require(
  "LendingPoolAddressesProvider"
);
const ERC20token = artifacts.require("MockERC20");
const ADai = artifacts.require("ADai");

contract("noLossDao", (accounts) => {
  let aaveLendingPool;
  let lendingPoolAddressProvider;
  let poolDeposits;
  let noLossDao;
  let dai;
  let aDai;

  const applicationAmount = "500";
  const _daoMembershipMinimum = "500000";

  const voter1 = accounts[1];
  const voter2 = accounts[2];
  const voter3 = accounts[3];
  const voter4 = accounts[4];
  const proposalOwner = accounts[5];

  beforeEach(async () => {
    dai = await ERC20token.new("AveTest", "AT", 18, accounts[0], {
      from: accounts[0],
    });
    aDai = await ADai.new(dai.address, {
      from: accounts[0],
    });
    aaveLendingPool = await AaveLendingPool.new(aDai.address, dai.address, {
      from: accounts[0],
    });
    lendingPoolAddressProvider = await LendingPoolAddressProvider.new(
      aaveLendingPool.address,
      {
        from: accounts[0],
      }
    );

    noLossDao = await NoLossDao.new({ from: accounts[0] });

    poolDeposits = await PoolDeposits.new(
      dai.address,
      aDai.address,
      lendingPoolAddressProvider.address,
      noLossDao.address,
      applicationAmount,
      _daoMembershipMinimum,
      { from: accounts[0] }
    );

    await noLossDao.initialize(poolDeposits.address, "1800", {
      from: accounts[0],
    });
  });

  it("NoLossDao:incentiveMechanism. Interest is split correctly to the user if they vote consistantly", async () => {
    let mintAmount1 = new BN(_daoMembershipMinimum).add(new BN("400000"));
    let mintAmount2 = new BN(_daoMembershipMinimum).add(new BN("500000"));
    let mintAmount3 = new BN(_daoMembershipMinimum).add(new BN("600000"));
    let mintAmount4 = new BN(_daoMembershipMinimum).add(new BN("700000"));

    // Note currently we have hardcoded that the 'interest will be the same as the amount deposited'
    // Therefore a deposit of 60000000000 should yield 60000000000 in interest....

    await expectRevert(
      noLossDao.distributeFunds(),
      "iteration interval not ended"
    );

    // deposit

    await dai.mint(voter1, mintAmount1);
    await dai.approve(poolDeposits.address, mintAmount1, {
      from: voter1,
    });
    await dai.mint(voter2, mintAmount2);
    await dai.approve(poolDeposits.address, mintAmount2, {
      from: voter2,
    });
    await dai.mint(voter3, mintAmount3);
    await dai.approve(poolDeposits.address, mintAmount3, {
      from: voter3,
    });
    await dai.mint(voter4, mintAmount4);
    await dai.approve(poolDeposits.address, mintAmount4, {
      from: voter4,
    });
    await poolDeposits.deposit(mintAmount1, { from: voter1 });
    await poolDeposits.deposit(mintAmount2, { from: voter2 });
    await poolDeposits.deposit(mintAmount3, { from: voter3 });
    await poolDeposits.deposit(mintAmount4, { from: voter4 });

    await time.increase(time.duration.seconds(1810));
    await noLossDao.distributeFunds(); // iteration 0 ends

    await dai.mint(proposalOwner, applicationAmount);
    await dai.approve(poolDeposits.address, applicationAmount, {
      from: proposalOwner,
    });
    // TODO: get the proposalID from chain rather than hard-coding
    const proposalID1 = 1;

    await poolDeposits.createProposal("Some IPFS hash string", {
      from: proposalOwner,
    });

    await noLossDao.voteDirect(proposalID1, 100, 10, { from: voter1 });
    await noLossDao.voteDirect(proposalID1, 100, 10, { from: voter2 });

    await time.increase(time.duration.seconds(1810));
    const proposalIterationOfFirstVote = await noLossDao.proposalIteration.call();
    const totalInterestEarnedForFirstVote = await poolDeposits.interestAvailable.call();
    await noLossDao.distributeFunds(); // iteration 1 ends

    let voter1BalanceBeforeVote = await dai.balanceOf(voter1);
    assert.equal(
      voter1BalanceBeforeVote.toString(),
      "0",
      "balance should be zero at the beginning of the period"
    );
    // Because they voted in the previous iteration they are eligible to recieve a cut of the interest earned.
    const {
      voteIncentiveStake: voteIncentiveStakeVoter1,
    } = await poolDeposits.usersVotingCreditAndVoteIncentiveState.call(voter1);
    const {
      voteIncentiveStake: voteIncentiveStakeVoter2,
    } = await poolDeposits.usersVotingCreditAndVoteIncentiveState.call(voter2);
    assert.equal(
      voteIncentiveStakeVoter1.toString(),
      mintAmount1
        .sub(new BN(_daoMembershipMinimum).mul(new BN(80)).div(new BN(100)))
        .toString(),
      "Voters stake is incorrect"
    );
    const totalStakeVotedInPreviousIteration = await noLossDao.totalStakedVoteIncentiveInIteration.call(
      proposalIterationOfFirstVote
    );
    assert.equal(
      voteIncentiveStakeVoter1.add(voteIncentiveStakeVoter2).toString(),
      totalStakeVotedInPreviousIteration.toString(),
      "TotalStaked isn't correct"
    );
    const totalAvailablePayoutPreviousIteration = await noLossDao.totalIterationVotePayout.call(
      proposalIterationOfFirstVote
    );
    assert.equal(
      totalInterestEarnedForFirstVote.toString(),
      totalAvailablePayoutPreviousIteration.toString(),
      "TotalStaked isn't correct"
    );

    // assert

    await noLossDao.voteDirect(proposalID1, 100, 10, { from: voter1 });

    let voter1BalanceAfterVote = await dai.balanceOf(voter1);
    assert.equal(
      voter1BalanceAfterVote.toString(),
      totalInterestEarnedForFirstVote
        .mul(voteIncentiveStakeVoter1)
        .div(totalStakeVotedInPreviousIteration)
        .toString(),
      "Should payout the correct incentive amount to the user"
    );
  });
});
