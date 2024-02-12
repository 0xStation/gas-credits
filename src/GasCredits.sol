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
        "GasPermit(address sponsor,address signer,uint256 nonce,uint48 validUntil,uint48 validAfter,bytes32 draftUserOpHash)"
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
        uint48 validUntil;
        uint48 validAfter;
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
            permit.draftUserOpHash = keccak256(_pack(userOp));
            // verify permit signature
            bool sigFailed = _verifyPermit(permit);
            if (permit.sponsor != permit.signer && !isDelegated(permit.sponsor, permit.signer)) {
                revert InvalidDelegation();
            }
            return (abi.encode(permit.sponsor), _packValidationData(sigFailed, permit.validUntil, permit.validAfter));
        }
    }

    /// @notice Validate sponsor has enough GAS
    /// @param sponsor Address of the sponsoring entity
    /// @param maxCost Amount of maximum gas (lower-case) to be consumed by the user operation
    /// @param maxFeePerGas Maximum fee (ETH) per unit gas
    function _validateSponsorBalance(address sponsor, uint256 maxCost, uint256 maxFeePerGas) internal {
        if (balanceOf(sponsor) < (maxCost + VERIFICATION_OVERHEAD) * maxFeePerGas) {
            revert InsufficientGasCredits();
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
                permit.validUntil,
                permit.validAfter,
                permit.sponsor,
                permit.signer,
                permit.nonce,
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
            uint48(bytes6(paymasterAndData[92:98])), // uint48 validUntil
            uint48(bytes6(paymasterAndData[98:104])), // uint48 validAfter
            bytes32(0), // empty draftUserOpHash
            paymasterAndData[104:] // bytes signature
        );
    }

    /// @notice Pack a UserOperation into dynamic bytes to be signed when sponsoring via delegation
    /// @dev Forked from Pimlico's VerifyingPaymaster: https://optimistic.etherscan.io/address/0x4df91e173a6cdc74efef6fc72bb5df1e8a8d7582#code
    /// @param userOp UserOperation to pack
    function _pack(UserOperation calldata userOp) internal pure returns (bytes memory ret) {
        bytes calldata pnd = userOp.paymasterAndData;
        // copy directly the userOp from calldata up to (but not including) the paymasterAndData.
        // also remove the two pointers to the paymasterAndData and the signature (which are 64 bytes long).
        // this encoding depends on the ABI encoding of calldata, but is much lighter to copy
        // than referencing each field separately.

        // the layout of the UserOp calldata is:

        // sender: 32 bytes - the sender address
        // nonce: 32 bytes - the nonce
        // initCode offset: 32 bytes - the offset of the initCode (this is the offset instead of the initCode itself because it's dynamic bytes)
        // callData offset: 32 bytes - the offset of the callData (this is the offset instead of the callData itself because it's dynamic bytes)
        // callGasLimit: 32 bytes - the callGasLimit
        // verificationGasLimit: 32 bytes - the verificationGasLimit
        // preVerificationGas: 32 bytes - the preVerificationGas
        // maxFeePerGas: 32 bytes - the maxFeePerGas
        // maxPriorityFeePerGas: 32 bytes - the maxPriorityFeePerGas
        // paymasterAndData offset: 32 bytes - the offset of the paymasterAndData (this is the offset instead of the paymasterAndData itself because it's dynamic bytes)
        // signature offset: 32 bytes - the offset of the signature (this is the offset instead of the signature itself because it's dynamic bytes)
        // initCode: dynamic bytes - the initCode
        // callData: dynamic bytes - the callData
        // paymasterAndData: dynamic bytes - the paymasterAndData
        // signature: dynamic bytes - the signature

        // during packing, we remove the signature offset, the paymasterAndData offset, the paymasterAndData, and the signature.
        // however, we need to glue the initCode and callData back together with the rest of the UserOp

        assembly {
            let ofs := userOp
            // the length of the UserOp struct, up to and including the maxPriorityFeePerGas field
            let len1 := 288
            // the length of the initCode and callData dynamic bytes added together (skipping the paymasterAndData offset and signature offset)
            let len2 := sub(sub(pnd.offset, ofs), 384)
            let totalLen := add(len1, len2)
            ret := mload(0x40)
            mstore(0x40, add(ret, add(totalLen, 32)))
            mstore(ret, totalLen)
            calldatacopy(add(ret, 32), ofs, len1)
            // glue the first part of the UserOp back with the initCode and callData
            calldatacopy(add(add(ret, 32), len1), add(add(ofs, len1), 64), len2)
        }

        // in the end, we are left with:

        // sender: 32 bytes - the sender address
        // nonce: 32 bytes - the nonce
        // initCode offset: 32 bytes - the offset of the initCode (this is the offset instead of the initCode itself because it's dynamic bytes)
        // callData offset: 32 bytes - the offset of the callData (this is the offset instead of the callData itself because it's dynamic bytes)
        // callGasLimit: 32 bytes - the callGasLimit
        // verificationGasLimit: 32 bytes - the verificationGasLimit
        // preVerificationGas: 32 bytes - the preVerificationGas
        // maxFeePerGas: 32 bytes - the maxFeePerGas
        // maxPriorityFeePerGas: 32 bytes - the maxPriorityFeePerGas
        // initCode: dynamic bytes - the initCode
        // callData: dynamic bytes - the callData

        // the initCode offset and callData offset are now incorrect, but we don't need them anyway so we can ignore them.
    }
}
