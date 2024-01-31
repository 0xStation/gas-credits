# Tokenized gas for the ERC-4337 ecosystem.

### Quickstart:

1. Mint $GAS with a 1:1 deposit of native token (eg. ETH)
2. Spend $GAS on ERC-4337 User Operations

### Benefits:

1. **Align protocol incentives**: guarantee use of funds on transaction subsidization
2. **Decentralize sponsorship**: any $GAS holder can sponsor any other account
3. **Sponsorship interoperability**: one standard signature schema for sponsoring user operations
4. **Token interoperability**: distribute and track $GAS with existing token-based tooling

### Implementation overview:

1. Permissionless singleton contract, [GasToken.sol](./src/GasToken.sol): an ERC-20 token and ERC-4337 paymaster in one
2. When minting $GAS, deposited ETH is deposited to the EntryPoint
3. Users self-subisize by spending their own tokens
4. Sponsors delegate permitting authority to offchain gas policy services
5. Delegates sign permits to spend tokens on behalf of sponsors

## Interactions

### Mint $GAS

Before subsidizing user operations, we first need to mint Gas Tokens ($GAS). Tokens are minted by depositing ETH through the `mint()` function. 
This ETH is then atomically deposited into ERC-4337's EntryPoint, enabling the contract to pay for user operations. There is no cap to the token supply
and there is no way to unwrap tokens other than when payment is made to the bundler when processing a user operation. Additionally a `mintTo(address recipient)`
exists for conveniently depositing newly minted tokens in an external address like a Safe.

<img width="1220" alt="image" src="https://github.com/0xStation/gas-token/assets/38736612/dcf74cc5-85c5-4d17-8bbc-bd5b90269690">

### Distribute $GAS 

Given the flexibility of the paymaster's design, many different personas can hold $GAS and participate in gas subsidization. Distributing directly to 
users' ERC-4337 wallets enables them to consume the token on their own user operations. Distributing to dApps enables them to sponsor users from
their interface, driving onchain engagement. Distributing to wallet providers enables them to sponsor users across multiple dApps. Distributing to bundlers
enables them to offer gas subsidization to their customers at lower cost, further accellerating growth of free transactions for users.

Because $GAS is an ERC-20 token, it's simple to distribute in batch via apps like [Disperse](https://disperse.app/) or equivalent. Station is launching a companion web app
for protocols, dApps, and users to mint, distribute, and spend Gas Tokens in Q1 2024.

### Spend $GAS -- User self-sponsors from wallet balance

The simplest way to spend $GAS is to hold it in an ERC-4337 smart contract account and submit a user operation. The user's signature over the user operation
is the native authentication needed to burn the needed $GAS from their balance to pay the bundler. Users are free to transfer $GAS across their accounts and take
their subsidization rewards wherever they go and with any account they choose.

<img width="1093" alt="image" src="https://github.com/0xStation/gas-token/assets/38736612/a833185c-5851-4cc7-8c53-a3c1dcd065e0">

### Spend $GAS -- User sponsored by a third party (eg dApp)

To serve gas policy automation needs for dApps and wallet providers, $GAS includes a sponsor and delegation mechanism. Sponsors will have their $GAS burned
to cover bundler fees and entrust delegates to run gas policies for them. ERC-1271 compatible smart contract accounts are recommended for delegates to enable safe key rotation
and other security precautions. Investigation into a standard RPC set for creating and querying gas policies is of high interest to further interoperability for the ERC-4337 ecosystem.

<img width="1179" alt="image" src="https://github.com/0xStation/gas-token/assets/38736612/8f50854e-27b1-425d-83ba-5e126774d60a">
