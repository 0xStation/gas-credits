## Gas Credits ($GAS) are tokenized gas for the ERC-4337 ecosystem.

Quickstart:

1. Mint $GAS with a 1:1 deposit of native token (eg. ETH).
2. Redeem $GAS through ERC-4337 User Operations.

Benefits:

1. **Align protocol incentives**: guarantee future purchase of blockspace when minting credits
2. **Leverage interoperability**: distribute and track credits with existing token-based tooling
3. **Decentralize sponsorship**: any $GAS holder can sponsor any user without centralized bundlers

Implementation overview:

1. One immutable contract, [GasCredits.sol](./src/GasCredits.sol): ERC-20 token and ERC-4337 paymaster in one
2. When minting $GAS, deposited ETH is deposited to the Entrypoint
3. Users spend their own credits by passing empty paymaster data in the UserOp
4. Sponsors sign permits to spend credits on specific UserOps
5. Sponsors delegate permitting authority to another account

### Interactions

Mint $GAS

<img width="1178" alt="image" src="https://github.com/0xStation/gas-credits/assets/38736612/6af6adbe-23c5-493a-8bb1-14e98c9d1cc0">

Redeem $GAS -- User spends credits

<img width="1205" alt="image" src="https://github.com/0xStation/gas-credits/assets/38736612/4dfe6047-b8e1-4f8d-8935-05bbaf24faf3">

Redeem $GAS -- User sponsored

<img width="1210" alt="image" src="https://github.com/0xStation/gas-credits/assets/38736612/e66fb87b-c1ec-411a-8ef1-865c2c81663f">

Redeem $GAS -- User sponsored with delegate

<img width="1243" alt="image" src="https://github.com/0xStation/gas-credits/assets/38736612/c2f2f4d4-d96b-42f2-9dcc-2d121914e95f">
