// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {RecyclingBatchNFT} from "../src/RecyclingBatchNFT.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";
import {EnergyFactors} from "../src/product/EnergyFactors.sol";
import {IRecyclingBatch} from "../src/interfaces/IRecyclingBatch.sol";

/// @notice Despliega el pasaporte de producto v2 (energía por tipo) y su tabla de factores.
/// @dev Reutiliza los lotes y las ideas ya desplegados (deployments/<chainId>.json) y reemplaza en ese archivo
///      `CircularProductNFT`, agregando `EnergyFactors`. Después: `DeployLiving` y `DeployMarketplace`.
///
///      Quien ejecuta debe ser admin de `RecyclingBatchNFT` (para darle `CONSUMER_ROLE` al pasaporte nuevo).
///      Variables opcionales: ADMIN_ADDRESS, IMAGE_BASE_URI, MANUFACTURER_ADDRESS, VERIFIER_ADDRESS.
///
///      Cada contrato cuesta ~1.540 de gas por byte de código en Sepolia y el tope por transacción es 16,7 M: el
///      pasaporte pesa ~10 KB, así que el multiplicador debe dejar su límite bajo el tope (ver Makefile).
contract DeployProductV2 is Script {
    function run() external returns (EnergyFactors factors, CircularProductNFT products) {
        address deployer;
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        deployer = pk == 0 ? msg.sender : vm.addr(pk);
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        require(vm.exists(path), "DeployProductV2: faltan los NFTs de impacto");
        string memory json = vm.readFile(path);
        RecyclingBatchNFT batches = RecyclingBatchNFT(vm.parseJsonAddress(json, ".RecyclingBatchNFT"));
        address ideas = vm.parseJsonAddress(json, ".RecyclingIdeaNFT");
        require(address(batches).code.length > 0, "DeployProductV2: RecyclingBatchNFT sin codigo");
        require(
            batches.hasRole(batches.DEFAULT_ADMIN_ROLE(), deployer),
            "DeployProductV2: no eres admin de los lotes"
        );
        string memory imageBase = vm.envOr("IMAGE_BASE_URI", string("ipfs://"));
        uint256 startBlock = block.number;

        if (pk == 0) vm.startBroadcast();
        else vm.startBroadcast(pk);
        factors = new EnergyFactors(deployer);
        products = new CircularProductNFT(
            deployer,
            imageBase,
            IRecyclingBatch(address(batches)),
            IERC721(ideas),
            factors,
            CircularProductNFT.CleanCriteria({
                minRecycledContentBps: 3000, // >= 30 % contenido reciclado
                minRenewableEnergyBps: 5000, // >= 50 % energía renovable
                maxCo2eGramsPerKg: 2000 //     <= 2 kg CO2e por kg de producto
            })
        );
        batches.grantRole(batches.CONSUMER_ROLE(), address(products));

        address manufacturer = vm.envOr("MANUFACTURER_ADDRESS", address(0));
        address verifier = vm.envOr("VERIFIER_ADDRESS", address(0));
        if (manufacturer != address(0)) products.grantRole(products.MANUFACTURER_ROLE(), manufacturer);
        if (verifier != address(0)) products.grantRole(products.VERIFIER_ROLE(), verifier);

        if (admin != deployer) {
            _handOver(address(products), admin, deployer, true);
            _handOver(address(factors), admin, deployer, false);
        }
        vm.stopBroadcast();

        // Una simulación (sin --broadcast) no debe dejar direcciones falsas en deployments/.
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.writeJson(vm.toString(address(products)), path, ".CircularProductNFT");
            vm.writeJson(vm.toString(address(factors)), path, ".EnergyFactors");
            vm.writeJson(vm.toString(startBlock), path, ".productV2StartBlock");
        }

        console2.log("EnergyFactors      ", address(factors));
        console2.log("CircularProductNFT ", address(products));
        console2.log(
            "Siguiente: redesplegar el marketplace (DeployMarketplace) para que apunte al pasaporte nuevo"
        );
    }

    function _handOver(address target, address admin, address deployer, bool withPauser) internal {
        (bool ok,) = target.call(abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), admin));
        require(ok, "grant admin");
        if (withPauser) {
            (ok,) = target.call(
                abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("PAUSER_ROLE"), admin)
            );
            require(ok, "grant pauser");
            (ok,) = target.call(
                abi.encodeWithSignature("renounceRole(bytes32,address)", keccak256("PAUSER_ROLE"), deployer)
            );
            require(ok, "renounce pauser");
        }
        (ok,) = target.call(abi.encodeWithSignature("renounceRole(bytes32,address)", bytes32(0), deployer));
        require(ok, "renounce admin");
    }
}
