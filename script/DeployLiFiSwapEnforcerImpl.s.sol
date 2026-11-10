// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { LiFiSwapEnforcer } from "../src/enforcers/LiFiSwapEnforcer.sol";

/**
 * @title DeployLiFiSwapEnforcerImpl
 * @notice CREATE2-deploys a new LiFiSwapEnforcer implementation and does not touch the proxy.
 * @dev The salt is packed the same way as `UpgradeLiFiSwapEnforcer` (`bytes32(abi.encodePacked(...))`).
 *      Foundry broadcasts the salted create through the canonical CREATE2 factory, so the same salt and
 *      bytecode land at the same address on every chain. A later upgrade calls `ProxyAdmin.upgradeAndCall`
 *      with that address and must not CREATE2 this salt again.
 * @dev run the script with:
 *      IMPL_SALT_V2=GATOR2 forge script script/DeployLiFiSwapEnforcerImpl.s.sol \
 *        --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast \
 *        --sender <deployer EOA>
 */
contract DeployLiFiSwapEnforcerImpl is Script {
    bytes32 implSalt;

    function setUp() public {
        implSalt = bytes32(abi.encodePacked(vm.envString("IMPL_SALT_V2")));
        console2.log("~~~");
        console2.log("Deployer: %s", msg.sender);
        console2.log("Implementation salt:");
        console2.logBytes32(implSalt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        // Implementation only. No proxy deploy and no upgradeAndCall.
        LiFiSwapEnforcer newImpl = new LiFiSwapEnforcer{ salt: implSalt }();
        console2.log("New implementation (proxy unchanged): %s", address(newImpl));

        vm.stopBroadcast();
    }
}
