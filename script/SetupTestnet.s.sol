// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice SOLO TESTNET. Asigna todos los roles operativos a las wallets de prueba para poder recorrer
///         los flujos completos (plantar/verificar, recolectar/acopiar/reciclar/fabricar, organizar/verificar).
/// @dev Requiere que el deployer siga siendo admin (desplegar sin ADMIN_ADDRESS).
///      Recuerda: los contratos impiden auto-verificarse, así que usa al menos 2 wallets
///      (una actúa, otra verifica).
///
///      TESTERS=0xabc...,0xdef... forge script script/SetupTestnet.s.sol --rpc-url amoy --broadcast
contract SetupTestnet is Script {
    function run() external {
        require(block.chainid != 137, "SetupTestnet: no usar en mainnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address[] memory testers = vm.envAddress("TESTERS", ",");

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        address trees = vm.parseJsonAddress(json, ".TreeNFT");
        address ideas = vm.parseJsonAddress(json, ".RecyclingIdeaNFT");
        address batches = vm.parseJsonAddress(json, ".RecyclingBatchNFT");
        address products = vm.parseJsonAddress(json, ".CircularProductNFT");
        address cleanups = vm.parseJsonAddress(json, ".CleanupActionNFT");

        bytes32 verifier = keccak256("VERIFIER_ROLE");
        bytes32[6] memory batchRoles = [
            keccak256("COLLECTOR_ROLE"),
            keccak256("COLLECTION_CENTER_ROLE"),
            keccak256("RECYCLER_ROLE"),
            keccak256("MANUFACTURER_ROLE"),
            keccak256("HAZARDOUS_HANDLER_ROLE"),
            verifier
        ];

        vm.startBroadcast(pk);
        for (uint256 i; i < testers.length; ++i) {
            address t = testers[i];
            IAccessControl(trees).grantRole(verifier, t);
            IAccessControl(ideas).grantRole(verifier, t);
            for (uint256 r; r < batchRoles.length; ++r) {
                IAccessControl(batches).grantRole(batchRoles[r], t);
            }
            IAccessControl(products).grantRole(keccak256("MANUFACTURER_ROLE"), t);
            IAccessControl(products).grantRole(verifier, t);
            IAccessControl(cleanups).grantRole(keccak256("ORGANIZER_ROLE"), t);
            IAccessControl(cleanups).grantRole(verifier, t);
            console2.log("roles asignados a", t);
        }
        vm.stopBroadcast();
    }
}
