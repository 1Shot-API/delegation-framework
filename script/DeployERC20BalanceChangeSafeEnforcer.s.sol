// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

import { ERC20BalanceChangeSafeEnforcer } from "../src/enforcers/ERC20BalanceChangeSafeEnforcer.sol";

/**
 * @title DeployCaveatEnforcers
 * @notice Deploys the suite of caveat enforcers to be used with the Delegation Framework.
 * @dev These contracts are likely already deployed on a testnet or mainnet as many are singletons.
 * @dev run the script with:
 * forge script script/DeployCaveatEnforcers.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployCaveatEnforcers is Script {
    bytes32 salt;
    IDelegationManager delegationManager;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));

        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address deployedAddress;

        deployedAddress = address(new ERC20BalanceChangeSafeEnforcer{ salt: salt }());
        console2.log("ERC20BalanceChangeSafeEnforcer: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
