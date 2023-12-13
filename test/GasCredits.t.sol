// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";
import {SimpleAccount} from "account-abstraction/samples/SimpleAccount.sol";
import {GasCredits} from "src/GasCredits.sol";

contract GasCreditsTest is Test {
    string SEPOLIA_RPC_URL;
    uint256 sepoliaFork;

    GasCredits public gasCredits;
    IEntryPoint entryPoint;
    EntryPoint testEntryPoint;
    SimpleAccount simpleAccountImpl;
    SimpleAccount userAccount;

    uint256 userPrivateKey;
    address user;

    UserOperation userOp;

    function setUp() public {
        SEPOLIA_RPC_URL = vm.envString("SEPOLIA_RPC_URL");
        sepoliaFork = vm.createFork(SEPOLIA_RPC_URL);
        vm.selectFork(sepoliaFork);

        entryPoint = IEntryPoint(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
        testEntryPoint = new EntryPoint();
        gasCredits = new GasCredits(testEntryPoint);

        userPrivateKey = 0xbeefEEbabe;
        user = vm.addr(userPrivateKey);

        simpleAccountImpl = new SimpleAccount(testEntryPoint);
        userAccount = SimpleAccount(payable(address(new ERC1967Proxy(address(simpleAccountImpl), ''))));
        userAccount.initialize(user);
    }

    function test_handleOps() public { 
        userOp = UserOperation({
            sender: address(userAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 100_000,
            verificationGasLimit: 100_000,
            preVerificationGas: 1_000_000, // 1mil
            maxFeePerGas: 1_000_000_000, // 1gwei
            maxPriorityFeePerGas: 0,
            paymasterAndData: "",
            signature: ""
        });

        bytes32 userOpHash = testEntryPoint.getUserOpHash(userOp);
        bytes32 ethSignUserOpHash = ECDSA.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, ethSignUserOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        userOp.signature = sig;
        
        UserOperation[] memory userOps = new UserOperation[](1);
        userOps[0] = userOp;

        
        testEntryPoint.depositTo{value: 10_000_000_000_000_000}(address(userAccount));
        testEntryPoint.handleOps(userOps, payable(address(0x1)));
    }

    function test_handleOpsPaymaster() public {
        // 21000 / batchSize + 4*zeroBytes + 16*nonZeroBytes + 25*userOpWords+22874
        uint256 _preVerificationGas = 21000 + 4 * 11 + 25 * 11 + 22874;
        // not using separate sponsor so permi hash and sig are unused
        bytes32 permitHash = bytes32(0x0);
        bytes32 permitSig = bytes32(0x0);
        userOp = UserOperation({
            sender: address(userAccount),
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 100_000,
            verificationGasLimit: 100_000,
            preVerificationGas: _preVerificationGas,
            maxFeePerGas: 1_000_000_000, //1gwei
            maxPriorityFeePerGas: 0,
            paymasterAndData: abi.encodePacked(address(gasCredits), address(userAccount), userOp.nonce, uint48(0), uint48(0), permitHash, permitSig),
            signature: ""
        });

        bytes32 userOpHash = testEntryPoint.getUserOpHash(userOp);
        bytes32 ethSignUserOpHash = ECDSA.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, ethSignUserOpHash);
        bytes memory sig = abi.encodePacked(r, s, v);
        userOp.signature = sig;
        
        UserOperation[] memory userOps = new UserOperation[](1);
        userOps[0] = userOp;

        uint256 balance = 1000000000_000_000_000_000_000_000_000_000;
        vm.deal(address(userAccount), balance);
        vm.prank(address(userAccount));
        gasCredits.mint{value: balance}();

        // console2.logUint(entryPoint.getDepositInfo(address(gasCredits)).deposit);
        testEntryPoint.handleOps(userOps, payable(address(0x1)));
    }
}
