# Interoperable gas credits for the ERC-4337 ecosystem.

### Quickstart:

1. Create gas credits with a 1:1 deposit of native credit (eg. ETH)
2. Spend gas credits on ERC-4337 User Operations

### Benefits:

1. **Align protocol incentives**: guarantee use of funds on transaction subsidization
2. **Decentralize sponsorship**: any $GAS holder can sponsor any other account
3. **Sponsorship interoperability**: one standard signature schema for sponsoring user operations
4. **Token interoperability**: distribute and track $GAS with existing credit-based tooling

### Implementation overview:

1. Permissionless singleton contract, [GasToken.sol](./src/GasToken.sol): an ERC-4337 paymaster and ERC-20 credit in one
2. When creating gas credits, deposited ETH is deposited to the EntryPoint
3. Users self-subisize by spending their own credits
4. Sponsors delegate permitting authority to offchain gas policy services
5. Delegates sign permits to spend credits on behalf of sponsors

## Interactions

### Mint $GAS

Before subsidizing user operations, we first need to mint Gas Credits ($GAS). Tokens are minted by depositing ETH through the `mint()` function. 
This ETH is then atomically deposited into ERC-4337's EntryPoint, enabling the contract to pay for user operations. There is no cap to the credit supply
and there is no way to unwrap credits other than when payment is made to the bundler when processing a user operation. Additionally a `mintTo(address recipient)`
exists for conveniently depositing newly minted credits in an external address like a Safe.

<img width="1220" alt="image" src="https://github.com/0xStation/gas-credit/assets/38736612/dcf74cc5-85c5-4d17-8bbc-bd5b90269690">

### Distribute $GAS 

Given the flexibility of the paymaster's design, many different personas can hold $GAS and participate in gas subsidization. Distributing directly to 
users' ERC-4337 wallets enables them to consume the credit on their own user operations. Distributing to dApps enables them to sponsor users from
their interface, driving onchain engagement. Distributing to wallet providers enables them to sponsor users across multiple dApps. Distributing to bundlers
enables them to offer gas subsidization to their customers at lower cost, further accellerating growth of free transactions for users.

Because $GAS is an ERC-20 credit, it's simple to distribute in batch via apps like [Disperse](https://disperse.app/) or equivalent. Station is launching a companion web app
for protocols, dApps, and users to mint, distribute, and spend Gas Tokens in Q1 2024.

### Spend $GAS -- User self-sponsors from wallet balance

The simplest way to spend $GAS is to hold it in an ERC-4337 smart contract account and submit a user operation. The user's signature over the user operation
is the native authentication needed to burn the needed $GAS from their balance to pay the bundler. Users are free to transfer $GAS across their accounts and take
their subsidization rewards wherever they go and with any account they choose.

<img width="1093" alt="image" src="https://github.com/0xStation/gas-credit/assets/38736612/a833185c-5851-4cc7-8c53-a3c1dcd065e0">

### Spend $GAS -- User sponsored by a third party (eg dApp)

To serve gas policy automation needs for dApps and wallet providers, $GAS includes a sponsor and delegation mechanism. Sponsors will have their $GAS burned
to cover bundler fees and entrust delegates to run gas policies for them. For example, a dApp would hold 1 GAS in a Safe and delegate to Station to run a gas policy of 1 sponsored user operation per user per day. Station's wallet and any wallets that want to leverage Station's gas policy network query for sponsorship before submitting a user operation, receive a "Gas Permit", and submit the user operation with this sponsorship approval.

Note: ERC-1271 compatible smart contract accounts are recommended for delegates to enable safe key rotation and other security precautions. Investigation into a standard RPC set for creating and querying gas policies is of high interest to further interoperability for the ERC-4337 ecosystem.

<img width="1179" alt="image" src="https://github.com/0xStation/gas-credit/assets/38736612/8f50854e-27b1-425d-83ba-5e126774d60a">


## Signature Schema

The signature schema for Gas Permits follows [EIP-712](https://eips.ethereum.org/EIPS/eip-712).

Domain:
```solidity
EIP712Domain(
  string name, // "GasToken"
  uint256 chainId,
  address verifyingContract, // GasToken contract, permissionless singleton with same address on all networks
)
```

Types:
```solidity
GasPermit(
  address sponsor, // entity who pays for the user op and has GAS balance deducted
  address signer, // either the sponsor, or a delegate of the sponsor
  uint256 nonce, // nonce for the signer, separate from the user operation's nonce and stored in GasToken for replay protection
  uint48 validUntil, // when this permit expires
  uint48 validAfter, // when this permit becomes active
  bytes32 draftUserOpHash, // hash of user operation with pruned paymasterAndData and signature fields
)
```

The derivation of this schema came about from reading existing paymaster implementations from Pimlico and Alchemy. While the signatures on those paymasters have less fields than here,
the same components are at play: the `sponsor` is analogous to the paymaster address, `signer` analogous to a signer (typically one) that each paymaster trusts, `nonce` analogous to some other custom nonce system for replay protection. The other parameters for `valid*` and a hashed subset of the user operation are consistently present in other signature-based paymasters. The GasToken paymaster essentially turns every GAS holder into a sponsor and enables them to choose their own signers for automating subsidization, unbundling the same components for maximum flexibility and interoperability.

## Contract Deployment

The GasToken contract is an ownerless, permissionless contract meant to be a singleton per-chain. Having a canonical address across all environments will help keep developer friction to a minimum and reduce risk of potential scammers posing as alternative options. Deploying through the [Deterministic Deployment Proxy](https://github.com/Arachnid/deterministic-deployment-proxy) with first-class support from Foundry will enable permissionless deployment of the contract on any EVM chain. When the time to deploy an official v1 comes, a pre-mine will also be done to optimize the address with enough leading zeros to bring additional gas savings. Official v1 deployment is phased for the end of February, after the new EntryPoint implementation is finalized and hopefully before ETH Denver 2024.

## Collaborating

GasToken is open to all input from the community. Specific engineering goals and needs will be advertised in the Issues of this repository.

We are particularly interested in collaborating with L2s to create the first protocol-wide gas incentive programs with this system. Additionally, we would like to help any and all bundlers and wallet providers integrate with the contract.
