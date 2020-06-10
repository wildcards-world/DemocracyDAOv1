# DAO ranking DAO contracts

This is for the https://gitcoin.co/issue/DemocracyEarth/DemocracyDAO/1/4386

A Quadratic voting DAO used to rank other DAOs.

# SYSTEM RULES

Spoke quite a bit to Santiago to better understand the system requirements and think I've got a good system in place that we can tweak slightly.

Going to outline a couple of the major design decisions:

1. Not using MolochDAO as this is bit of a 'fitting a square peg into a round hole' idea. Its got some nice elements, but its quite different and we aren't really using this DAO for funding.

2. We split the logic into 2 main contracts. The deposits contract is non-upgradeable and provides guarantees to participants that they will always be able to withdraw their initial stake at some point in time. The dao voting logic contract is separate and upgradeable. This will allow admin some crucial modification ability as they monitor the behavior of the project; but the users have complete peace that no matter what changes are made to the voting logic, they will be able to withdraw their deposit. (This contract has already been audited: https://dao.care/dao.care_smart_contract_audit.pdf)

3. We are using dai as the DAO currency. In order to incentivise DAO participation, we are using aave to earn interest on locked dai, and awarding that to users when they participate. In essence this is similar to a product like [kickback](https://kickback.events) but for DAOs based on the interest earned.

4. So much of getting QV right is designing against sybil attacks to ensure the QV voting system cannot be gamed. We are initially planning on using a minimum deposit threshold before vote power kicks in to guard against sybil, i.e. if you need to say join the DAO with a minimum of 500 dai, and your 'vote credits' are only the excess of this figure. There is lots more explain, but I will try give a brief system characterization.

The system works in iterations, with the length of an iteration being configurable (my suggestion is maybe quarterly). This allows us to define a point in time where previous votes have decayed and users will need to reassess their voting decisions and cast again. This designs against set it and forget it behaviour (and actually the mechanism alluded to in #3 incentivises active continued participation). It also gives gives windows for users to enter and exit the DAO in a way that cannot be malicious and swing the vote. For example, it isn't possible to join the DAO, vote, withdraw your deposit within the same iteration; if this were possible, people would be able to manipulate the vote with the same funds/DAI.

**Aside**: Another idea we had was to turn the DAO into something like PoolTogether, where every iteration 1 lucky voter wins the interest. We experimented integrating Chainlink VRF on Kovan and Ropsten for this as a verifiable source of randomness to chose one voter. We ultimately decided that a kickback kind of structure would form a better incentive; but you can get creative with these mechanisms.

Lets move away from iterations and talk quick about proposals and users.

Proposals "i.e. will be other DAOs", can be submitted by anyone (to list their dao), but they require some stake in the system to stop spamming. This is configurable but lets say its 50 dai for now (this DAI will also generate interest and incentivise participation). They can either be in an active state where they are voted for, or, they may be withdrawn by the proposer, no longer allowing this dao to be voted for. Users join the DAO at anytime with minimum threshold amount of dai (basic sybil defense). This dai gets lent out on the Aave protocol to generate the interest (however any similar system could be used, from mstable to compound to DSR). We believe that without actively using the locked funds to incentivise users participation in this DAO will be low, and voter apathy will be high. Users can quadratic vote for each project once during an iteration, but they can vote for multiple projects until they have run out of 'voice credits'. There are plenty of modifiers to safegaurd against attacks, and certain requirements to ensure the contract isn't vulnerable to flash loan votes etc.

[Buidler](https://buidler.dev/) is awesome and the entire suite of tests run in only 22s. I have also created a code coverage report showing that 93% of the code in the smart contract has been covered by those tests. It was a fun system to design and build.

# Summary of DAO rules:

- Cannot vote in the iteration you join (only the next one)

  - this is to increase the commitment, and make the distribution of interest earned more fair (if you earned the participation incentive but only joined the DAO 5 minutes before the iteration it is a bit unfair).

- Cannot withdraw if you have voted

  - this is to protect the integrity of the DAO and make sure that the deposit stays in the pool the full time to make the incentive payouts more fair. It also acts as an anti sybil deterant.

- Cannot change your vote. This rule could be changed, but that is how it is implemented now.

- Cannot vote for the same organisation twice.

- Can vote for multiple organisations.

# Summary of the DAO incentive mechanism:

When you vote, you become eligible to collect a portion of the interest earned during that period next time you vote. Therefore, to collect any of this voting reward you need to vote at least 2 times.

Each user has a value called their `usersVoteIncentiveStake`. This value is the number of votes/'voice credits' the have per iteration + 20% of the minimum deposit.

The contract keeps track of a global mapping called `totalStakedVoteIncentiveInIteration`. When a user participates in an iteration `totalStakedVoteIncentiveInIteration[iteration#]` is added to with the number of votes/'voice credits' the user has and 20 percent of the minimum deposit. We didn't make it 100% of the users deposit as part of an anti-sybil mechanism; basically, you earn very little of the voting incentive if you deposit just more than the minimum deposit. Now - not only is it financially expensive to create multiple accounts due to the minimum deposit, but you also earn much higher percentages of the incentive if you pool all your funds into a single deposit.

Thus: `amountPayedAsParticipationIncentive = totalIterationVotePayout[previousIteration] * (usersVoteIncentiveStake / totalStakedVoteIncentiveInIteration[previousIteration]`

If any of these incentives aren't collected they go towards the next week's incentives; thus over time the incentive to participate will remain strong.

### install

```bash
yarn
```

### Run the tests:

```bash
yarn run test
```

```bash
yarn run coverage
```

### Clean Deploy

```bash
yarn run clean
```

```bash
yarn run deploy -- --network <network name you want to deploy to>
```

### License

Code License:
MIT
