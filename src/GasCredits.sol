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

    // 4337
    IEntryPoint public immutable entryPoint;
    uint256 private immutable GAS_OVERHEAD = 69420;
    // signatures
    bytes32 private constant GAS_PERMIT_TYPE_HASH = keccak256(
        "GasPermit(address sponsor,uint256 nonce,uint48 validUntil,uint48 validAfter,bytes32 draftUserOpHash)"
    );
    bytes32 private constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("Gas Credits");
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;
    uint256 internal immutable INITIAL_CHAIN_ID;

    struct GasPermit {
        address sponsor;
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

    function mint() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        _mint(_msgSender(), msg.value);
    }

    function validatePaymasterUserOp(UserOperation calldata userOp, bytes32, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData)
    {
        if (msg.sender != address(entryPoint)) SenderNotEntrypoint();

        GasPermit memory permit = parsePaymasterAndData(userOp.paymasterAndData);
        bool sigFailed = false;
        if (balanceOf(permit.sponsor) < maxCost + GAS_OVERHEAD * userOp.maxFeePerGas) {
            revert InsufficientGasCredits();
        }
        if (permit.sponsor != userOp.sender) {
            // use nonce, reverts if already used
            _useNonce(permit.sponsor, permit.nonce);
            // compress userOp into hash with empty paymaster data and signature
            permit.draftUserOpHash = keccak256(_pack(userOp));
            // verify permit signature
            sigFailed = _verifyPermit(permit);
        }

        return (abi.encode(permit.sponsor), _packValidationData(sigFailed, permit.validUntil, permit.validAfter));
    }

    function postOp(PostOpMode, bytes calldata context, uint256 actualGasCost) external {
        if (msg.sender != address(entryPoint)) SenderNotEntrypoint();

        address sponsor = abi.decode(context, (address));
        _burn(sponsor, actualGasCost + GAS_OVERHEAD * tx.gasprice);
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
                permit.nonce,
                permit.draftUserOpHash
            )
        );
        // hash domain with permit values
        bytes32 permitHash = ECDSA.toTypedDataHash(
            INITIAL_CHAIN_ID == block.chainid ? INITIAL_DOMAIN_SEPARATOR : _domainSeparator(), valuesHash
        );
        // return if permit is valid
        return SignatureChecker.isValidSignatureNow(permit.sponsor, permitHash, permit.signature);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPE_HASH, NAME_HASH, block.chainid, address(this)));
    }

    /*=============
        USER OP
    =============*/

    function parsePaymasterAndData(bytes calldata paymasterAndData) public pure returns (GasPermit memory gasPermit) {
        (address sponsor, uint256 nonce, uint48 validUntil, uint48 validAfter, bytes memory signature) =
            abi.decode(paymasterAndData[20:], (address, uint256, uint48, uint48, bytes));
        return GasPermit(sponsor, nonce, validUntil, validAfter, bytes32(0), signature);
    }

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
