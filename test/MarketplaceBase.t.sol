// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {ToKleanToken} from "../src/token/ToKleanToken.sol";
import {ToKleanMarketplace} from "../src/marketplace/ToKleanMarketplace.sol";
import {ToKleanCatalog} from "../src/marketplace/ToKleanCatalog.sol";
import {ToKleanMerchantRegistry} from "../src/marketplace/ToKleanMerchantRegistry.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";

/// @dev Impacto (NFTs) + economía (token) + marketplace (registro, catálogo y pedidos), con roles separados.
abstract contract MarketplaceBase is BaseTest {
    address merchantAdmin = makeAddr("merchantAdmin");
    address arbiter = makeAddr("arbiter");
    address treasury = makeAddr("treasury");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");

    uint16 constant FEE = 200; // 2 %
    uint16 constant POR_BPS = 1000; // 10 %
    string constant META = "ipfs://bafylisting";

    ToKleanToken token;
    ToKleanMerchantRegistry registry;
    ToKleanCatalog catalog;
    ToKleanMarketplace market;
    uint256 TKN;
    uint256 REC;
    uint256 POR;

    function setUp() public virtual override {
        super.setUp();
        token = new ToKleanToken(admin, 1_000_000_000 ether);
        TKN = token.TKN();
        REC = token.REC();
        POR = token.POR();
        registry = new ToKleanMerchantRegistry(admin);
        catalog = new ToKleanCatalog(products, registry, admin);
        market = new ToKleanMarketplace(token, catalog, registry, admin, treasury, FEE, POR_BPS);

        bytes32 minter = token.MINTER_ROLE();
        bytes32 marketplaceRole = registry.MARKETPLACE_ROLE();
        bytes32 merchantAdminRole = registry.MERCHANT_ADMIN_ROLE();
        bytes32 arbiterRole = market.ARBITER_ROLE();
        vm.startPrank(admin);
        token.grantRole(minter, admin);
        token.grantRole(minter, address(market));
        catalog.setMarketplace(address(market));
        registry.grantRole(marketplaceRole, address(market));
        registry.grantRole(merchantAdminRole, merchantAdmin);
        market.grantRole(arbiterRole, arbiter);
        vm.stopPrank();

        _approveMerchant(seller);
        _fundBuyer(buyer, 1_000 ether);
    }

    function _approveMerchant(address who) internal {
        vm.prank(who);
        registry.applyAsMerchant("ipfs://bafyprofile");
        vm.prank(merchantAdmin);
        registry.reviewMerchant(who, true);
    }

    function _fundBuyer(address who, uint256 amount) internal {
        vm.prank(admin);
        token.mint(who, TKN, amount);
        vm.prank(admin);
        token.mint(who, REC, amount);
        vm.prank(who);
        token.setApprovalForAll(address(market), true);
    }

    function _list(uint128 price, uint32 stock) internal returns (uint256) {
        vm.prank(seller);
        return catalog.createListing(ToKleanCatalog.Kind.Product, TKN, price, stock, META, false, 0);
    }

    function _buy(uint256 listingId, uint32 qty) internal returns (uint256) {
        uint128 price = catalog.getListing(listingId).price;
        vm.prank(buyer);
        return market.buy(listingId, qty, price);
    }

    function _ship(uint256 orderId) internal {
        vm.prank(seller);
        market.markShipped(orderId, "ipfs://bafytracking");
    }

    /// @dev Crea un producto limpio certificado perteneciente a `owner_`.
    function _certifiedProduct(address owner_) internal returns (uint256 tokenId) {
        uint256 batchId = _batchAtManufacturer(10_000);
        CircularProductNFT.MaterialInput[] memory inputs = new CircularProductNFT.MaterialInput[](1);
        inputs[0] = CircularProductNFT.MaterialInput({batchId: batchId, grams: 8_000});
        CircularProductNFT.ManufacturingData memory data = CircularProductNFT.ManufacturingData({
            energyWh: 1_500,
            waterLiters: 3,
            co2eGrams: 5_000,
            wasteGrams: 20,
            renewableEnergyBps: 8000,
            reportHash: keccak256("lca-report"),
            reportURI: "ipfs://lca",
            facility: "Planta Rancagua"
        });
        vm.prank(manufacturer);
        tokenId = products.manufacture(owner_, "Banca de plastico reciclado", 10_000, inputs, data, 0);
        vm.prank(verifier);
        products.certify(tokenId, true, EV, URI);
    }

    function _listProduct(uint256 tokenId, uint128 price) internal returns (uint256) {
        vm.startPrank(seller);
        products.approve(address(catalog), tokenId);
        uint256 id = catalog.createListing(ToKleanCatalog.Kind.Product, TKN, price, 1, META, true, tokenId);
        vm.stopPrank();
        return id;
    }
}
