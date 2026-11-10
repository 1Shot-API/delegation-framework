// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeLiFiSwapEnforcer
 * @notice Points the existing LiFiSwapEnforcer proxy at an already-deployed implementation.
 * @dev Does not CREATE2 a new implementation. The GATOR2 implementation
 *      `0x6585DA9cc291EEd428C74CB83C11C665db8d4B52` is already on Base, Ethereum, and Arc.
 *      Redeploying that salt reverts. `msg.sender` must be the ProxyAdmin owner.
 *      Empty `data` skips the initializer delegatecall; the enforcer has no initializer and
 *      slots 0–1 stay in place.
 * @dev run the script with:
 *      NEW_IMPLEMENTATION=0x6585DA9cc291EEd428C74CB83C11C665db8d4B52 \
 *      LIFI_SWAP_ENFORCER_PROXY=0x29fcBBa852439616c4D614A2fa6411E42b760153 \
 *      PROXY_ADMIN=0x1798093F7B364f25D9Ad79E04313C6078C2c5FC8 \
 *      forge script script/UpgradeLiFiSwapEnforcer.s.sol --rpc-url <your_rpc_url> \
 *        --private-key $PROXY_ADMIN_OWNER_KEY --broadcast \
 *        --sender <PROXY_ADMIN_OWNER_EOA>
 */
contract UpgradeLiFiSwapEnforcer is Script {
    function setUp() public view {
        console2.log("~~~");
        console2.log("Sender (must be ProxyAdmin owner): %s", msg.sender);
    }

    function run() public {
        address proxy = vm.envAddress("LIFI_SWAP_ENFORCER_PROXY");
        address proxyAdmin = vm.envAddress("PROXY_ADMIN");
        address newImplementation = vm.envAddress("NEW_IMPLEMENTATION");
        console2.log("~~~");
        console2.log("Proxy:              %s", proxy);
        console2.log("ProxyAdmin:         %s", proxyAdmin);
        console2.log("New implementation: %s", newImplementation);

        address owner = ProxyAdmin(proxyAdmin).owner();
        require(msg.sender == owner, "UpgradeLiFiSwapEnforcer:sender-not-proxy-admin-owner");

        vm.startBroadcast();

        // Upgrade the proxy. The caller (msg.sender) must be the ProxyAdmin owner; ProxyAdmin.upgradeAndCall
        // enforces `onlyOwner` and the transparent proxy only accepts upgradeToAndCall from its admin.
        // Empty `_data` => no init delegatecall (the enforcer has no initializer).
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), newImplementation, "");
        console2.log("Proxy upgraded. Proxy address unchanged: %s", proxy);

        vm.stopBroadcast();
    }
}
