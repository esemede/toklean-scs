// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TreeNFT} from "../src/TreeNFT.sol";
import {RecyclingBatchNFT} from "../src/RecyclingBatchNFT.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";
import {MaterialType} from "../src/common/Types.sol";

/// @notice Siembra datos de demostración (árboles, lotes con custodia completa y productos limpios) para
///         desarrollar y probar el frontend. SÓLO anvil local (chainId 31337): jamás en redes públicas.
///
///         anvil &  make deploy-local && make deploy-economy-local && forge script script/SeedDemo.s.sol --rpc-url local --broadcast
///
/// Actores (mnemónico de anvil): 0 admin, 1 colector, 2 centro de acopio, 3 recicladora, 4 fabricante,
/// 5 auditor, 7 plantador.
contract SeedDemo is Script {
    bytes32 constant EV = keccak256("demo-evidence");
    string constant URI = "ipfs://bafydemoevidence";

    TreeNFT trees;
    RecyclingBatchNFT batches;
    CircularProductNFT products;

    uint256 admin;
    uint256 collector;
    uint256 center;
    uint256 recycler;
    uint256 manufacturer;
    uint256 auditor;
    uint256 planter;

    function run() external {
        require(block.chainid == 31337, unicode"SeedDemo: sólo anvil local");
        string memory mnemonic = vm.envOr("MNEMONIC", string("test test test test test test test test test test test junk"));
        admin = vm.deriveKey(mnemonic, 0);
        collector = vm.deriveKey(mnemonic, 1);
        center = vm.deriveKey(mnemonic, 2);
        recycler = vm.deriveKey(mnemonic, 3);
        manufacturer = vm.deriveKey(mnemonic, 4);
        auditor = vm.deriveKey(mnemonic, 5);
        planter = vm.deriveKey(mnemonic, 7);

        string memory json = vm.readFile("deployments/31337.json");
        trees = TreeNFT(vm.parseJsonAddress(json, ".TreeNFT"));
        batches = RecyclingBatchNFT(vm.parseJsonAddress(json, ".RecyclingBatchNFT"));
        products = CircularProductNFT(vm.parseJsonAddress(json, ".CircularProductNFT"));

        _roles();
        _trees();
        uint256 b1 = _batchToManufacturer(MaterialType.PET, 120_000, unicode"Santiago - Punto limpio Maipú");
        uint256 b2 = _batchToManufacturer(MaterialType.PET, 60_000, unicode"Santiago - Punto limpio Ñuñoa");
        _collectionOnly(MaterialType.HDPE, 80_000, unicode"Valparaíso - Feria libre");
        _collectionOnly(MaterialType.Aluminum, 15_000, unicode"Concepción - Centro de acopio");

        // Producto 1: cumple los tres criterios y queda certificado por el auditor.
        uint256 p1 = _manufacture("Banca de plastico reciclado", 100_000, b1, 90_000, 40_000, 150_000, 6000);
        // Producto 2: declarado pero no cumple (energía renovable y CO2e) -> queda pendiente de auditoría.
        _manufacture("Maceta de plastico reciclado", 100_000, b2, 40_000, 30_000, 300_000, 2000);

        vm.startBroadcast(auditor);
        products.certify(p1, true, EV, URI);
        vm.stopBroadcast();

        console2.log("Seed listo: 3 arboles (2 verificados), 4 lotes, 2 productos (1 certificado)");
    }

    function _roles() internal {
        vm.startBroadcast(admin);
        trees.grantRole(trees.VERIFIER_ROLE(), vm.addr(auditor));
        batches.grantRole(batches.VERIFIER_ROLE(), vm.addr(auditor));
        batches.grantRole(batches.COLLECTOR_ROLE(), vm.addr(collector));
        batches.grantRole(batches.COLLECTION_CENTER_ROLE(), vm.addr(center));
        batches.grantRole(batches.RECYCLER_ROLE(), vm.addr(recycler));
        batches.grantRole(batches.MANUFACTURER_ROLE(), vm.addr(manufacturer));
        products.grantRole(products.MANUFACTURER_ROLE(), vm.addr(manufacturer));
        products.grantRole(products.VERIFIER_ROLE(), vm.addr(auditor));
        vm.stopBroadcast();
    }

    function _trees() internal {
        vm.startBroadcast(planter);
        trees.plant("Quillay", -33_448_900, -70_669_300, 0, EV, URI);
        trees.plant("Peumo", -33_501_200, -70_580_100, 0, EV, URI);
        trees.plant("Litre", -33_410_000, -70_700_000, 0, EV, URI);
        vm.stopBroadcast();

        vm.startBroadcast(auditor);
        trees.verifyPlanting(1, true, 22, EV, URI);
        trees.verifyPlanting(2, true, 18, EV, URI);
        vm.stopBroadcast();
    }

    function _collectionOnly(MaterialType material, uint96 grams, string memory origin) internal returns (uint256 id) {
        vm.startBroadcast(collector);
        id = batches.registerCollection(material, grams, origin, EV, URI);
        vm.stopBroadcast();
    }

    function _batchToManufacturer(MaterialType material, uint96 grams, string memory origin) internal returns (uint256 id) {
        id = _collectionOnly(material, grams, origin);
        address c = vm.addr(center);
        address r = vm.addr(recycler);
        address m = vm.addr(manufacturer);
        vm.startBroadcast(collector);
        batches.dispatch(id, c);
        vm.stopBroadcast();
        vm.startBroadcast(center);
        batches.acceptBatch(id, grams, EV, URI);
        batches.recordSorting(id, grams, EV, URI);
        batches.dispatch(id, r);
        vm.stopBroadcast();
        vm.startBroadcast(recycler);
        batches.acceptBatch(id, grams, EV, URI);
        batches.recordProcessing(id, grams, EV, URI);
        batches.dispatch(id, m);
        vm.stopBroadcast();
        vm.startBroadcast(manufacturer);
        batches.acceptBatch(id, grams, EV, URI);
        vm.stopBroadcast();
    }

    function _manufacture(
        string memory name,
        uint96 massGrams,
        uint256 batchId,
        uint96 recycledGrams,
        uint64 energyWh,
        uint64 co2eGrams,
        uint16 renewableBps
    ) internal returns (uint256 id) {
        CircularProductNFT.MaterialInput[] memory inputs = new CircularProductNFT.MaterialInput[](1);
        inputs[0] = CircularProductNFT.MaterialInput({batchId: batchId, grams: recycledGrams});
        CircularProductNFT.ManufacturingData memory data = CircularProductNFT.ManufacturingData({
            energyWh: energyWh,
            waterLiters: 300,
            co2eGrams: co2eGrams,
            wasteGrams: 2_000,
            renewableEnergyBps: renewableBps,
            reportHash: EV,
            reportURI: URI,
            facility: "Planta Recicladora Sur"
        });
        vm.startBroadcast(manufacturer);
        id = products.manufacture(vm.addr(manufacturer), name, massGrams, inputs, data, 0);
        vm.stopBroadcast();
    }
}
