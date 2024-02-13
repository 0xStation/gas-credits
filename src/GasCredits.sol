// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {SignatureChecker, ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IPaymaster} from "lib/account-abstraction/contracts/interfaces/IPaymaster.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {UserOperation} from "lib/account-abstraction/contracts/interfaces/UserOperation.sol";
import "lib/account-abstraction/contracts/core/Helpers.sol";
import {NonceBitMap} from "./utils/NonceBitMap.sol";

/// @title GasCredits
/// @notice Tokenized gas for the ERC-4337 ecosystem.
/// @author Conner (@ilikesymmetry)
/// @author Station (@0xstation)
contract GasCredits is ERC20, NonceBitMap, IPaymaster {
    bytes32 private constant GAS_PERMIT_TYPE_HASH = keccak256(
        "GasPermit(address sponsor,address signer,uint256 nonce,uint48 validAfter,uint48 validUntil,bytes32 draftUserOpHash)"
    );
    bytes32 private constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("GasCredits");
    bytes32 private immutable INITIAL_DOMAIN_SEPARATOR;
    uint256 private immutable INITIAL_CHAIN_ID;

    uint256 private constant VERIFICATION_OVERHEAD = 14600;
    IEntryPoint public immutable entryPoint;

    mapping(address sponsor => mapping(address delegate => bool delegated)) private _delegations;

    error SenderNotEntrypoint();
    error InsufficientGasCredits();
    error InvalidDelegation();

    event Delegate(address indexed sponsor, address indexed delegate);
    event Undelegate(address indexed sponsor, address indexed delegate);

    struct GasPermit {
        address sponsor;
        address signer;
        uint256 nonce;
        uint48 validAfter;
        uint48 validUntil;
        bytes32 draftUserOpHash;
        bytes signature;
    }

    /// @notice Constructor
    /// @param _entryPoint Address of the Entrypoint
    constructor(IEntryPoint _entryPoint) ERC20("Gas Credits", "GAS") {
        entryPoint = _entryPoint;
        INITIAL_DOMAIN_SEPARATOR = _domainSeparator();
        INITIAL_CHAIN_ID = block.chainid;
    }

    /// @notice ONLY FOR TESTING - redeem balance back to ETH
    /// @dev Locking constraint lifted while in development for easily reusing testnet ETH on new contracts
    function redeem() external {
        uint256 balance = balanceOf(msg.sender);
        entryPoint.withdrawTo(payable(msg.sender), balance);
        _burn(msg.sender, balance);
    }

    /// @notice Mint GAS by depositing ETH 1:1
    function mint() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        _mint(msg.sender, msg.value);
    }

    /// @notice Mint GAS to another address by depositing ETH 1:1
    /// @param recipient The recipient of newly minted GAS
    function mintTo(address recipient) external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        _mint(recipient, msg.value);
    }

    /// @notice Validate user operation sponsors has sufficient GAS and valid signature
    /// @param userOp UserOperation to sponsor
    /// @param maxCost Maximum cost in gas (lower-case)
    function validatePaymasterUserOp(UserOperation calldata userOp, bytes32, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData)
    {
        if (msg.sender != address(entryPoint)) revert SenderNotEntrypoint();

        // only 20 bytes for paymaster address, implicit auth that sender is sponsor
        if (userOp.paymasterAndData.length == 20) {
            // validate sender has enough GAS balance to cover userOp
            _validateSponsorBalance(userOp.sender, maxCost, userOp.maxFeePerGas);
            // return sender, not sigFailed, null validUntil, null validAfter
            return (abi.encode(userOp.sender), _packValidationData(false, 0, 0));
        } else {
            // parse paymaster data for permit for sponsorship
            GasPermit memory permit = parsePaymasterAndData(userOp.paymasterAndData);
            _validateSponsorBalance(permit.sponsor, maxCost, userOp.maxFeePerGas);
            // use nonce, reverts if already used
            _useNonce(permit.signer, permit.nonce);
            // compress userOp into hash with empty paymaster data and signature
            permit.draftUserOpHash = hashDraftUserOp(userOp);
            // verify permit signature
            bool sigFailed = _verifyPermit(permit);
            if (permit.sponsor != permit.signer && !isDelegated(permit.sponsor, permit.signer)) {
                revert InvalidDelegation();
            }
            return (abi.encode(permit.sponsor), _packValidationData(sigFailed, permit.validUntil, permit.validAfter));
        }
    }

    /// @notice Burn GAS that was consumed by a user operation
    /// @param context ABI encoding of sponsor address
    /// @param actualGasCost Amount of gas (lower-case) that was consumed by the user operation
    function postOp(PostOpMode, bytes calldata context, uint256 actualGasCost) external {
        if (msg.sender != address(entryPoint)) revert SenderNotEntrypoint();

        address sponsor = abi.decode(context, (address));
        _burn(sponsor, actualGasCost + VERIFICATION_OVERHEAD * tx.gasprice);
    }

    /*=============
        BALANCE
    =============*/

    /// @notice Decimals override for ERC20 balance cosmetics
    /// @dev 12 was chosen so transaction fee values on popular L2s are easily read (order of 0.1-100s)
    function decimals() public pure override returns (uint8) {
        return 12; // 1 ETH = 1_000_000 GAS
    }

    /// @notice Validate sponsor has enough GAS
    /// @param sponsor Address of the sponsoring entity
    /// @param maxCost Amount of maximum gas (lower-case) to be consumed by the user operation
    /// @param maxFeePerGas Maximum fee (ETH) per unit gas
    function _validateSponsorBalance(address sponsor, uint256 maxCost, uint256 maxFeePerGas) internal view {
        if (balanceOf(sponsor) < maxCost + (maxFeePerGas * VERIFICATION_OVERHEAD)) {
            revert InsufficientGasCredits();
        }
    }

    /*==============
        DELEGATE
    ==============*/

    /// @notice Delegate ability to sponsor to another address
    /// @dev Most useful for enabling offchain services to run subsidization policies
    /// @param to Address of the delegate that supports EIP-1271 or ECDSA signature verification
    function delegate(address to) external {
        _delegations[msg.sender][to] = true;
        emit Delegate(msg.sender, to);
    }

    /// @notice Undelegate ability to sponsor to another address
    /// @param from Address of the delegate to cancel
    function undelegate(address from) external {
        delete _delegations[msg.sender][from];
        emit Undelegate(msg.sender, from);
    }

    /// @notice Check if sponsor has delegated to a signer
    /// @param sponsor Entity sponsoring user operations by deducting their GAS balance
    /// @param signer Entity issuing GasPermits to sponsor user operations
    /// @return delegated If delegation exists
    function isDelegated(address sponsor, address signer) public view returns (bool delegated) {
        return _delegations[sponsor][signer];
    }

    /*================
        SIGNATURES
    ================*/

    /// @notice Verify the signer, signature, and data align and revert otherwise
    /// @param permit GasPermit to verify
    /// @return sigFailed If signature verification failed
    function _verifyPermit(GasPermit memory permit) private view returns (bool sigFailed) {
        // hash permit values
        bytes32 valuesHash = keccak256(
            abi.encode(
                GAS_PERMIT_TYPE_HASH,
                permit.sponsor,
                permit.signer,
                permit.nonce,
                permit.validAfter,
                permit.validUntil,
                permit.draftUserOpHash
            )
        );
        // hash domain with permit values
        bytes32 permitHash = ECDSA.toTypedDataHash(
            INITIAL_CHAIN_ID == block.chainid ? INITIAL_DOMAIN_SEPARATOR : _domainSeparator(), valuesHash
        );
        // return if signature failed = permit is NOT valid
        sigFailed = !SignatureChecker.isValidSignatureNow(permit.signer, permitHash, permit.signature);
    }

    /// @notice EIP712 domain separator for GasPermit verification
    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPE_HASH, NAME_HASH, block.chainid, address(this)));
    }

    /*=============
        USER OP
    =============*/

    /// @notice Convert user operation's paymasterAndData into GasPermit struct
    /// @param paymasterAndData Paymaster address (this contract) and packed data about the GasPermit
    /// @dev If a sender is paying for the user operation from their own GAS balance,
    ///      this function is not called and paymasterAndData is just the paymaster address
    function parsePaymasterAndData(bytes calldata paymasterAndData) public pure returns (GasPermit memory gasPermit) {
        return GasPermit(
            address(bytes20(paymasterAndData[20:40])), // address sponsor
            address(bytes20(paymasterAndData[40:60])), // address signer
            uint256(bytes32(paymasterAndData[60:92])), // uint256 nonce
            uint48(bytes6(paymasterAndData[92:98])), // uint48 validAfter
            uint48(bytes6(paymasterAndData[98:104])), // uint48 validUntil
            bytes32(0), // empty draftUserOpHash
            paymasterAndData[104:] // bytes signature
        );
    }

    /// @notice Hash a partial UserOperation for use in a Gas Permit
    /// @param userOp UserOperation to trim and hash
    /// @dev chainId and paymaster address will be included in EIP712Domain
    function hashDraftUserOp(UserOperation calldata userOp) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.callGasLimit,
                userOp.verificationGasLimit,
                userOp.preVerificationGas,
                userOp.maxFeePerGas,
                userOp.maxPriorityFeePerGas
            )
        );
    }
}
