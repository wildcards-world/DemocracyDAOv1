# DAO ranking DAO contracts

This is for the https://gitcoin.co/issue/DemocracyEarth/DemocracyDAO/1/4386

A Quadratic voting DAO used to rank other DAOs.

# SYSTEM RULES

Spoke quite a bit to Santiago to better understand the system requirements and think I've got a good system in place that we can tweak slightly.

Going to outline a couple of the major design decisions:

1. Not using MolochDAO as this is bit of a fitting a square peg into a round hole. Its got some nice elements, but its quite different and we aren't really using this DAO for funding.

2. We split the logic into 2 main contracts. The deposits contract is non-upgradeable and provides guarantees to participants that they will always be able to withdraw their initial stake at some point in time. The dao voting logic contract is separate and upgradeable. This will allow admin some crucial modification ability as they monitor the behavior of the project.

3. We are using dai as the DAO currency. In order to incentivize DAO participation, dai is a nice currency we can use in some other defi applications.

4. So much of getting QV right is designing against sybil attacks to ensure the QV voting system cannot be gamed. We are initially planning on using a min join threshold before vote power kicks in to guard against sybil, i.e. if you need to say join the DAO with a minimum of 500 dai, and your 'vote credits' are only the excess of this figure. There is lots more explain, but I will try give a brief system characterization.

The system works in iterations, with the length of an iteration being configurable (my suggestion is maybe quarterly). This allows us to define a point in time where previous votes have decayed and users will need to reassess their voting decisions and cast again. This designs against set it and forget it behavior. It also gives gives windows for users to enter and exit the DAO in a way that cannot be malicious and swing the vote. There are a lot more subtleties to it. It also provides a perfect point to distribute the interest generated from the DAO over the past quarter. I envision this interest should be sent to someone that has voted, as a means to encourage voting. I have successfully deployed and integrated Chainlink VRF on Kovan and Ropsten before, this would provide a verifiable source of randomness to chose one voter. These are just my opinion to incentivize voters at the moment.

Lets move away from iterations and talk quick about proposals and users.

Proposals "i.e. will be other DAOs", can be submitted by anyone (to list their dao), but they require some stake in the system to stop spamming. This is configurable but lets say its 50 dai for now. They can either be in an active state where they are voted for, or, they may be withdrawn by the proposer, no longer allowing this dao to be voted for. Users join the DAO at anytime with minimum threshold amount of dai (basic sybil defense). This dai gets lent out on the Aave protocol to generate some basic interest (useful to incentivize the voting prize). This is important as otherwise users are unlikely to lock up their funds in this dao to rank daos, unless they can have some basic motivation. Users can quadratic vote for a each of project once during an iteration. There are plenty of modifiers to safegaurd against attacks, and certain requirements to ensure the contract isn't vulnerable to flash loan votes etc.

Buidler is awesome and the entire suite of tests run in only 22s. I have also created a code coverage report showing that 93% of the code in the smart contract has been covered by those tests. It was a fun system to design and build.

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

If you want to save the deployment for the UI or the twitter bot:

```bash
yarn run save-deployment
```

### Upgrade

Prepair the upgrade by running instead of `yarn run clean`:

```bash
yarn run prepair-upgrade
```

### License

Code License:
MIT
