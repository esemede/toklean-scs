// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TreeNFT} from "../src/TreeNFT.sol";
import {RecyclingIdeaNFT} from "../src/RecyclingIdeaNFT.sol";
import {RecyclingBatchNFT} from "../src/RecyclingBatchNFT.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";
import {CleanupActionNFT} from "../src/CleanupActionNFT.sol";
import {IRecyclingBatch} from "../src/interfaces/IRecyclingBatch.sol";

/// @notice Despliega la suite de NFTs de impacto ToKlean.
/// @dev El deployer recibe temporalmente el rol admin para cablear permisos y luego lo cede a ADMIN_ADDRESS
///      (Safe multisig / Timelock de gobernanza) y renuncia a él.
///
///      forge script script/Deploy.s.sol --rpc-url amoy --broadcast --verify
contract Deploy is Script {
    function run()
        external
        returns (
            TreeNFT trees,
            RecyclingIdeaNFT ideas,
            RecyclingBatchNFT batches,
            CircularProductNFT products,
            CleanupActionNFT cleanups
        )
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // En testnet se puede omitir ADMIN_ADDRESS: el deployer queda como admin para asignar roles de prueba.
        address admin = vm.envOr("ADMIN_ADDRESS", deployer);
        uint256 startBlock = block.number;
        string memory imageBase = vm.envOr("IMAGE_BASE_URI", string("ipfs://"));

        vm.startBroadcast(pk);

        trees = new TreeNFT(deployer, imageBase);
        ideas = new RecyclingIdeaNFT(deployer, imageBase);
        batches = new RecyclingBatchNFT(deployer, imageBase);
        products = new CircularProductNFT(
            deployer,
            imageBase,
            IRecyclingBatch(address(batches)),
            IERC721(address(ideas)),
            CircularProductNFT.CleanCriteria({
                minRecycledContentBps: 3000, // >= 30 % contenido reciclado
                minRenewableEnergyBps: 5000, // >= 50 % energía renovable
                maxCo2eGramsPerKg: 2000 //     <= 2 kg CO2e por kg de producto
            })
        );
        cleanups = new CleanupActionNFT(deployer, imageBase);

        // El contrato de productos puede descontar material de los lotes.
        batches.grantRole(batches.CONSUMER_ROLE(), address(products));

        if (admin != deployer) {
            _handOver(address(trees), admin, deployer);
            _handOver(address(ideas), admin, deployer);
            _handOver(address(batches), admin, deployer);
            _handOver(address(products), admin, deployer);
            _handOver(address(cleanups), admin, deployer);
        }

        vm.stopBroadcast();

        _writeDeployment(trees, ideas, batches, products, cleanups, admin, startBlock);

        console2.log("TreeNFT            ", address(trees));
        console2.log("RecyclingIdeaNFT   ", address(ideas));
        console2.log("RecyclingBatchNFT  ", address(batches));
        console2.log("CircularProductNFT ", address(products));
        console2.log("CleanupActionNFT   ", address(cleanups));
    }

    /// @dev deployments/<chainId>.json lo consume el front (direcciones + bloque inicial para leer eventos).
    function _writeDeployment(
        TreeNFT trees,
        RecyclingIdeaNFT ideas,
        RecyclingBatchNFT batches,
        CircularProductNFT products,
        CleanupActionNFT cleanups,
        address admin,
        uint256 startBlock
    ) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "startBlock", startBlock);
        vm.serializeAddress(k, "admin", admin);
        vm.serializeAddress(k, "TreeNFT", address(trees));
        vm.serializeAddress(k, "RecyclingIdeaNFT", address(ideas));
        vm.serializeAddress(k, "RecyclingBatchNFT", address(batches));
        vm.serializeAddress(k, "CircularProductNFT", address(products));
        string memory json = vm.serializeAddress(k, "CleanupActionNFT", address(cleanups));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }

    function _handOver(address target, address admin, address deployer) internal {
        IAccessControlLike c = IAccessControlLike(target);
        c.grantRole(0x00, admin);
        c.grantRole(keccak256("PAUSER_ROLE"), admin);
        c.renounceRole(keccak256("PAUSER_ROLE"), deployer);
        c.renounceRole(0x00, deployer);
    }
}

interface IAccessControlLike {
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
}
