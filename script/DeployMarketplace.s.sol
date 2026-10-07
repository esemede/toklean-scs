// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ToKleanToken} from "../src/token/ToKleanToken.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";
import {ToKleanMerchantRegistry} from "../src/marketplace/ToKleanMerchantRegistry.sol";
import {ToKleanCatalog} from "../src/marketplace/ToKleanCatalog.sol";
import {ToKleanMarketplace} from "../src/marketplace/ToKleanMarketplace.sol";

/// @notice Despliega el marketplace (registro de comercios, catálogo y pedidos) sobre la economía y los NFTs de
///         impacto ya desplegados en la misma red.
/// @dev Lee `ToKleanToken` y `CircularProductNFT` de deployments/<chainId>.json y agrega `ToKleanMerchantRegistry`,
///      `ToKleanCatalog`, `ToKleanMarketplace` y `marketplaceStartBlock` sin tocar el resto.
///
///      Variables (todas opcionales salvo PRIVATE_KEY):
///        ADMIN_ADDRESS            Safe multisig dueño de los contratos (por defecto el deployer; en mainnet defínelo)
///        TREASURY_ADDRESS         recibe las comisiones (por defecto ADMIN_ADDRESS)
///        MERCHANT_ADMIN_ADDRESS   comité que aprueba comercios (por defecto ADMIN_ADDRESS)
///        ARBITER_ADDRESS          resuelve disputas (por defecto ADMIN_ADDRESS)
///        MARKETPLACE_FEE_BPS      comisión por venta (200 = 2 %)
///        MARKETPLACE_POR_BPS      POR emitido al comprar un producto limpio (1000 = 10 % del pago)
///
///      Para emitir POR el marketplace necesita `MINTER_ROLE` en el token. Si el deployer es admin del token se
///      concede aquí; si no (p.ej. un Safe), el script lo avisa y debe concederse desde el Safe.
///
///      Cada contrato cuesta ~1.600 de gas por byte de código en Sepolia y el tope por transacción es 16,7 M,
///      por eso son tres contratos de menos de 10 KB:
///      forge script script/DeployMarketplace.s.sol --rpc-url sepolia --broadcast --gas-estimate-multiplier 800
contract DeployMarketplace is Script {
    struct Cfg {
        address admin;
        address treasury;
        address merchantAdmin;
        address arbiter;
        uint16 feeBps;
        uint16 porBps;
    }

    function run()
        external
        returns (ToKleanMerchantRegistry registry, ToKleanCatalog catalog, ToKleanMarketplace market)
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Cfg memory c = _config(deployer);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        require(vm.exists(path), "DeployMarketplace: despliega antes los NFTs y la economia");
        string memory json = vm.readFile(path);
        ToKleanToken token = ToKleanToken(vm.parseJsonAddress(json, ".ToKleanToken"));
        CircularProductNFT products = CircularProductNFT(vm.parseJsonAddress(json, ".CircularProductNFT"));
        require(address(token).code.length > 0, "DeployMarketplace: ToKleanToken sin codigo en esta red");
        require(address(products).code.length > 0, "DeployMarketplace: CircularProductNFT sin codigo");

        uint256 startBlock = block.number;
        bool canGrantMinter = token.hasRole(token.DEFAULT_ADMIN_ROLE(), deployer);

        vm.startBroadcast(pk);
        registry = new ToKleanMerchantRegistry(deployer);
        catalog = new ToKleanCatalog(products, registry, deployer);
        market = new ToKleanMarketplace(token, catalog, registry, deployer, c.treasury, c.feeBps, c.porBps);

        // Cableado: el catálogo sólo acepta reservas del marketplace; el registro, ventas y valoraciones suyas.
        catalog.setMarketplace(address(market));
        registry.grantRole(registry.MARKETPLACE_ROLE(), address(market));
        if (canGrantMinter) token.grantRole(token.MINTER_ROLE(), address(market));

        _handOver(registry, catalog, market, c, deployer);
        vm.stopBroadcast();

        // Una simulación (sin --broadcast) no debe dejar direcciones falsas en deployments/.
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.writeJson(vm.toString(address(registry)), path, ".ToKleanMerchantRegistry");
            vm.writeJson(vm.toString(address(catalog)), path, ".ToKleanCatalog");
            vm.writeJson(vm.toString(address(market)), path, ".ToKleanMarketplace");
            vm.writeJson(vm.toString(startBlock), path, ".marketplaceStartBlock");
        }

        console2.log("ToKleanMerchantRegistry", address(registry));
        console2.log("ToKleanCatalog         ", address(catalog));
        console2.log("ToKleanMarketplace     ", address(market));
        console2.log("treasury               ", c.treasury);
        if (!canGrantMinter) {
            console2.log(
                "AVISO: concede MINTER_ROLE del token al marketplace para emitir POR (hoy no lo tiene)"
            );
        }
    }

    /// @dev El admin (Safe) conserva control, pausa y parámetros; el deployer se retira de todo.
    function _handOver(
        ToKleanMerchantRegistry registry,
        ToKleanCatalog catalog,
        ToKleanMarketplace market,
        Cfg memory c,
        address deployer
    ) internal {
        if (c.merchantAdmin != deployer) {
            registry.grantRole(registry.MERCHANT_ADMIN_ROLE(), c.merchantAdmin);
        }
        if (c.arbiter != deployer) market.grantRole(market.ARBITER_ROLE(), c.arbiter);
        if (c.admin == deployer) return;

        registry.grantRole(registry.DEFAULT_ADMIN_ROLE(), c.admin);
        catalog.grantRole(catalog.DEFAULT_ADMIN_ROLE(), c.admin);
        catalog.grantRole(catalog.PAUSER_ROLE(), c.admin);
        catalog.grantRole(catalog.PARAMETERS_ROLE(), c.admin);
        market.grantRole(market.DEFAULT_ADMIN_ROLE(), c.admin);
        market.grantRole(market.PARAMETERS_ROLE(), c.admin);

        if (c.merchantAdmin != deployer) registry.renounceRole(registry.MERCHANT_ADMIN_ROLE(), deployer);
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), deployer);
        catalog.renounceRole(catalog.PAUSER_ROLE(), deployer);
        catalog.renounceRole(catalog.PARAMETERS_ROLE(), deployer);
        catalog.renounceRole(catalog.DEFAULT_ADMIN_ROLE(), deployer);
        if (c.arbiter != deployer) market.renounceRole(market.ARBITER_ROLE(), deployer);
        market.renounceRole(market.PARAMETERS_ROLE(), deployer);
        market.renounceRole(market.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _config(address deployer) internal view returns (Cfg memory c) {
        c.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        c.treasury = vm.envOr("TREASURY_ADDRESS", c.admin);
        c.merchantAdmin = vm.envOr("MERCHANT_ADMIN_ADDRESS", c.admin);
        c.arbiter = vm.envOr("ARBITER_ADDRESS", c.admin);
        c.feeBps = uint16(vm.envOr("MARKETPLACE_FEE_BPS", uint256(200)));
        c.porBps = uint16(vm.envOr("MARKETPLACE_POR_BPS", uint256(1000)));
        if (_isMainnet(block.chainid)) {
            require(c.admin != deployer, "DeployMarketplace: define ADMIN_ADDRESS (Safe)");
        }
    }

    function _isMainnet(uint256 id) internal pure returns (bool) {
        return id == 1 || id == 137 || id == 10 || id == 42161 || id == 8453 || id == 56 || id == 43114;
    }
}
