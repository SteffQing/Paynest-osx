// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Script, console} from "forge-std/Script.sol";
import {Paynest} from "../src/factory/Paynest.sol";

contract DeployPaynest is Script {
    function run() public {
        uint256 privKey = vm.envUint("DEPLOYMENT_PRIVATE_KEY");
        vm.startBroadcast(privKey);
        console.log("Deploying from:", vm.addr(privKey));

        // Deploy the address registry
        Paynest paynest = new Paynest();
        console.log("Paynest deployed at:", address(paynest));

        vm.stopBroadcast();

        // Print summary
        console.log("\nDeployment Summary");
        console.log("------------------");
        console.log("Chain ID:", block.chainid);
        console.log("Paynest:", address(paynest));
    }
}
