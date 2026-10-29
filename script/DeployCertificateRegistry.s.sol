// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {CertificateRegistry} from "../src/CertificateRegistry.sol";

/**
 * @title DeployCertificateRegistry
 * @notice Deployment script for CertiChain (CertificateRegistry).
 * @dev Inherits forge-std Script. Uses vm.startBroadcast() and vm.stopBroadcast()
 *      to record transactions that are signed and broadcast to the selected network.
 */
contract DeployCertificateRegistry is Script {
    /**
     * @notice Main entry point executed by `forge script`.
     * @return registry The newly deployed CertificateRegistry instance.
     */
    function run() external returns (CertificateRegistry registry) {
        // Starts recording all state-changing contract creations and calls
        // signed by the sender account configured in the forge script command
        vm.startBroadcast();

        // Deploy the CertificateRegistry contract
        registry = new CertificateRegistry();

        // Stops recording broadcast transactions
        vm.stopBroadcast();
    }
}
