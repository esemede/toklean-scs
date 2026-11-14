// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {LivingProduct, IProductPassport} from "../src/marketplace/LivingProduct.sol";

/// @notice Despliega `LivingProduct` (gemelo digital 90/10) sobre el `CircularProductNFT` de deployments/<chainId>.json.
/// @dev Va aparte porque su coste por byte en Sepolia exige otro multiplicador de gas que el del pasaporte (ver Makefile).
///      `DeployMarketplace` lo lee y lo registra en el catálogo.
contract DeployLiving is Script {
    function run() external returns (LivingProduct living) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        require(vm.exists(path), "DeployLiving: despliega antes el pasaporte (DeployProductV2)");
        address products = vm.parseJsonAddress(vm.readFile(path), ".CircularProductNFT");
        require(products.code.length > 0, "DeployLiving: CircularProductNFT sin codigo");

        if (pk == 0) vm.startBroadcast();
        else vm.startBroadcast(pk);
        living = new LivingProduct(IProductPassport(products));
        vm.stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.writeJson(vm.toString(address(living)), path, ".LivingProduct");
        }
        console2.log("LivingProduct", address(living));
    }
}
