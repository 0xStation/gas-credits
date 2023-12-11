// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IPaymaster} from "lib/account-abstraction/contracts/interfaces/IPaymaster.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {UserOperation} from "lib/account-abstraction/contracts/interfaces/UserOperation.sol";

contract GasCredits is ERC20, IPaymaster {
    IEntryPoint public immutable entryPoint;

    constructor(IEntryPoint _entryPoint) ERC20("Gas Credits", "GAS") {
        entryPoint = _entryPoint;
    }

    function mint() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        _mint(_msgSender(), msg.value);
    }

    function validatePaymasterUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData)
    {
        _requireFromEntryPoint();
    }

    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost) external {
        _requireFromEntryPoint();
    }

    /*===========
        UTILS
    ===========*/

    /// validate the call is made from a valid entrypoint
    function _requireFromEntryPoint() internal virtual {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");
    }
}
