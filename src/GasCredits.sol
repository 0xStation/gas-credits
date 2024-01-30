// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SignatureChecker, ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IPaymaster} from "lib/account-abstraction/contracts/interfaces/IPaymaster.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {UserOperation} from "lib/account-abstraction/contracts/interfaces/UserOperation.sol";
import "lib/account-abstraction/contracts/core/Helpers.sol";
import {NonceBitMap} from "./utils/NonceBitMap.sol";

contract GasCredits is ERC20, NonceBitMap, IPaymaster {
    error SenderNotEntrypoint();
    error InsufficientGasCredits();
    error InsufficientDelegation();

    // 4337
    IEntryPoint public immutable entryPoint;
    uint256 private immutable GAS_OVERHEAD = 69420;
    // signatures
    bytes32 private constant GAS_PERMIT_TYPE_HASH = keccak256(
        "GasPermit(address sponsor,address signer,uint256 nonce,uint48 validUntil,uint48 validAfter,bytes32 draftUserOpHash)"
    );
    bytes32 private constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("GasCredits");
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;
    uint256 internal immutable INITIAL_CHAIN_ID;

    // sponsor -> delegate -> value
    mapping(address => mapping(address => uint256)) public _delegations;

    event Delegate(address indexed sponsor, address indexed delegate, uint256 value);

    struct GasPermit {
        address sponsor;
        address signer;
        uint256 nonce;
        uint48 validUntil;
        uint48 validAfter;
        bytes32 draftUserOpHash;
        bytes signature;
    }

    constructor(IEntryPoint _entryPoint) ERC20("Gas Credits", "GAS") {
        entryPoint = _entryPoint;
        INITIAL_DOMAIN_SEPARATOR = _domainSeparator();
        INITIAL_CHAIN_ID = block.chainid;
    }

    // redeem $GAS for ETH, only used for ease of testing
    function redeem() external {
        uint256 balance = balanceOf(msg.sender);
        _burn(msg.sender, balance);
        entryPoint.withdrawTo(payable(msg.sender), balance);
    }

    // mint $GAS by depositing ETH 1:1
    function mint() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        _mint(_msgSender(), msg.value);
    }

    // mint $GAS to another address by depositing ETH 1:1
    function mintTo(address recipient) external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        _mint(recipient, msg.value);
    }

    // validate sponsors have sufficient $GAS and valid signatures
    function validatePaymasterUserOp(UserOperation calldata userOp, bytes32, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData)
    {
        if (msg.sender != address(entryPoint)) revert SenderNotEntrypoint();

        // only 20 bytes for paymaster address, implicit auth that sender is sponsor
        if (userOp.paymasterAndData.length == 20) {
            // validate sender has enough $GAS balance to cover userOp
            if (balanceOf(userOp.sender) < maxCost + GAS_OVERHEAD * userOp.maxFeePerGas) {
                revert InsufficientGasCredits();
            }
            // return sender, not sigFailed, null validUntil, null validAfter
            return (abi.encode(userOp.sender), _packValidationData(false, 0, 0));
        } else {
            // parse paymaster data for permit for sponsorship
            GasPermit memory permit = parsePaymasterAndData(userOp.paymasterAndData);
            if (balanceOf(permit.sponsor) < maxCost + GAS_OVERHEAD * userOp.maxFeePerGas) {
                revert InsufficientGasCredits();
            }
            // use nonce, reverts if already used
            _useNonce(permit.signer, permit.nonce);
            // compress userOp into hash with empty paymaster data and signature
            permit.draftUserOpHash = keccak256(_pack(userOp));
            // verify permit signature
            bool sigFailed = _verifyPermit(permit);
            if (permit.sponsor != permit.signer) {
                if (_delegations[permit.sponsor][permit.signer] < maxCost + GAS_OVERHEAD * userOp.maxFeePerGas) {
                    revert InsufficientDelegation();
                }
            }
            return (abi.encode(permit.sponsor), _packValidationData(sigFailed, permit.validUntil, permit.validAfter));
        }
    }

    // burn $GAS that was consumed by this UserOp
    function postOp(PostOpMode, bytes calldata context, uint256 actualGasCost) external {
        if (msg.sender != address(entryPoint)) revert SenderNotEntrypoint();

        address sponsor = abi.decode(context, (address));
        _burn(sponsor, actualGasCost + GAS_OVERHEAD * tx.gasprice);
    }

    /*==============
        DELEGATE
    ==============*/

    function delegate(address to, uint256 value) external {
        _delegations[msg.sender][to] = value;
        emit Delegate(msg.sender, to, value);
    }

    function delegation(address from, address to) external view returns (uint256 value) {
        return _delegations[from][to];
    }

    /*================
        SIGNATURES
    ================*/

    /// @notice Verify the signer, signature, and data align and revert otherwise
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
        // return if permit is valid
        return SignatureChecker.isValidSignatureNow(permit.signer, permitHash, permit.signature);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPE_HASH, NAME_HASH, block.chainid, address(this)));
    }

    /*=============
        USER OP
    =============*/

    // paymasterAndData is a bytes array with the first 20 bytes being this paymaster's address
    // and the remaining data encoded in one of two ways:
    // 1. sender == sponsor -> no further data needed, UserOp signature is implicit signature on payment
    // 2. sender != sponsor -> sponsor has a nonce, valid time range, and signature
    // 3. sender != sponsor && sponsor != signer -> signer has a nonce, valid time range, and signature
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

    // forked from Pimlico's VerifyingPaymaster: https://optimistic.etherscan.io/address/0x4df91e173a6cdc74efef6fc72bb5df1e8a8d7582#code
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
