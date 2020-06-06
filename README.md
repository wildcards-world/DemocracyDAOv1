# DAO ranking DAO contracts

This is for the https://gitcoin.co/issue/DemocracyEarth/DemocracyDAO/1/4386

A Quadratic voting DAO used to rank other DAOs.

# SYSTEM RULES

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
