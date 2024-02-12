// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {GasCredits} from "src/GasCredits.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";

contract DeployScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address entryPoint = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
        bytes32 salt = 0x4337433743374337433743374337433743374337433743374337433743374337;

        new GasCredits{salt: salt}(IEntryPoint(entryPoint));

        vm.stopBroadcast();
    }
}
