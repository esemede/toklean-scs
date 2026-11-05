// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MarketplaceBase} from "./MarketplaceBase.t.sol";
import {ToKleanCatalog} from "../src/marketplace/ToKleanCatalog.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";
import {ToKleanMerchantRegistry} from "../src/marketplace/ToKleanMerchantRegistry.sol";

contract ToKleanCatalogTest is MarketplaceBase {
    // ------------------------------------------------------------------ publicaciones

    function test_CreateListing() public {
        uint256 id = _list(10 ether, 5);
        assertEq(id, 1);
        ToKleanCatalog.Listing memory l = catalog.getListing(id);
        assertEq(l.seller, seller);
        assertEq(l.price, 10 ether);
        assertEq(l.stock, 5);
        assertEq(l.paymentId, TKN);
        assertEq(l.metadataHash, keccak256(bytes(META)));
        assertFalse(catalog.isCleanVerified(id));
        assertTrue(catalog.isAvailable(id));
        assertEq(catalog.listingCount(), 1);
    }

    function test_RevertWhen_ListingWithoutApprovedMerchant() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.NotMerchant.selector, stranger));
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, META, false, 0);
    }

    function test_RevertWhen_InvalidListingInputs() public {
        vm.startPrank(seller);
        vm.expectRevert(ToKleanCatalog.ZeroAmount.selector);
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 0, 1, META, false, 0);
        vm.expectRevert(ToKleanCatalog.ZeroAmount.selector);
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 0, META, false, 0);
        vm.expectRevert(ToKleanCatalog.InvalidUri.selector);
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, "", false, 0);
        vm.expectRevert(ToKleanCatalog.InvalidUri.selector);
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, string(new bytes(257)), false, 0);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.PaymentNotAccepted.selector, POR));
        catalog.createListing(ToKleanCatalog.Kind.Product, POR, 1 ether, 1, META, false, 0);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.PaymentNotAccepted.selector, 99));
        catalog.createListing(ToKleanCatalog.Kind.Product, 99, 1 ether, 1, META, false, 0);
        vm.stopPrank();
    }

    function test_UpdatePauseAndCloseListing() public {
        uint256 id = _list(10 ether, 5);
        vm.startPrank(seller);
        catalog.updateListing(id, 12 ether, 7, "ipfs://bafynew");
        catalog.setListingPaused(id, true);
        vm.stopPrank();
        ToKleanCatalog.Listing memory l = catalog.getListing(id);
        assertEq(l.price, 12 ether);
        assertEq(l.stock, 7);
        assertEq(l.metadataHash, keccak256("ipfs://bafynew"));
        assertFalse(catalog.isAvailable(id));

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.ListingNotAvailable.selector, id));
        market.buy(id, 1, 12 ether);

        vm.startPrank(seller);
        catalog.setListingPaused(id, false);
        catalog.closeListing(id);
        vm.stopPrank();
        l = catalog.getListing(id);
        assertEq(uint8(l.status), uint8(ToKleanCatalog.Status.Closed));
        assertEq(l.stock, 0);
        assertFalse(catalog.isAvailable(id));

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.ListingClosed.selector, id));
        catalog.updateListing(id, 1 ether, 1, META);
    }

    function test_RevertWhen_NotTheSellerEditsListing() public {
        uint256 id = _list(10 ether, 5);
        _approveMerchant(stranger);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.NotSeller.selector, id));
        catalog.updateListing(id, 1 ether, 1, META);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.NotSeller.selector, id));
        catalog.closeListing(id);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.NotSeller.selector, id));
        catalog.setListingPaused(id, true);
        vm.stopPrank();
    }

    function test_SuspendedMerchantListingsAreNotAvailable() public {
        uint256 id = _list(10 ether, 5);
        vm.prank(merchantAdmin);
        registry.setSuspended(seller, true);
        assertFalse(catalog.isAvailable(id));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.ListingNotAvailable.selector, id));
        market.buy(id, 1, 10 ether);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.NotMerchant.selector, seller));
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, META, false, 0);
    }

    // ------------------------------------------------------------------ productos limpios

    function test_CleanProductListingEscrowsNft() public {
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 200 ether);

        assertEq(products.ownerOf(tokenId), address(catalog));
        ToKleanCatalog.Listing memory l = catalog.getListing(id);
        assertTrue(l.hasProduct);
        assertTrue(l.nftEscrowed);
        assertEq(l.productTokenId, tokenId);
        assertTrue(catalog.isCleanVerified(id));
        assertTrue(catalog.isAvailable(id));
        assertEq(catalog.listingOfProduct(tokenId), id);
    }

    function test_RevertWhen_ProductListingRulesBroken() public {
        uint256 tokenId = _certifiedProduct(seller);
        vm.startPrank(seller);
        products.approve(address(catalog), tokenId);

        vm.expectRevert(ToKleanCatalog.ProductStockMustBeOne.selector);
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 2, META, true, tokenId);
        vm.expectRevert(ToKleanCatalog.ProductMustBeKindProduct.selector);
        catalog.createListing(ToKleanCatalog.Kind.Service, TKN, 1 ether, 1, META, true, tokenId);
        vm.stopPrank();

        // No es de su propiedad
        uint256 other = _certifiedProduct(stranger);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.ProductNotOwned.selector, other));
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, META, true, other);
    }

    function test_RevertWhen_ProductNotCertifiedOrRevoked() public {
        // Declarado, sin certificar
        uint256 batchId = _batchAtManufacturer(10_000);
        CircularProductNFT.MaterialInput[] memory inputs = new CircularProductNFT.MaterialInput[](1);
        inputs[0] = CircularProductNFT.MaterialInput({batchId: batchId, grams: 8_000});
        CircularProductNFT.ManufacturingData memory data = CircularProductNFT.ManufacturingData({
            energyWh: 1,
            waterLiters: 1,
            co2eGrams: 5_000,
            wasteGrams: 1,
            renewableEnergyBps: 8000,
            reportHash: keccak256("r"),
            reportURI: "ipfs://r",
            facility: "Planta"
        });
        vm.prank(manufacturer);
        uint256 declared = products.manufacture(seller, "Sin certificar", 10_000, inputs, data, 0);
        vm.startPrank(seller);
        products.approve(address(catalog), declared);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.ProductNotCertified.selector, declared));
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, META, true, declared);
        vm.stopPrank();

        // Un NFT inexistente tampoco sirve
        vm.prank(seller);
        vm.expectRevert();
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, META, true, 9999);

        // Certificado y luego revocado antes de comprar
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 10 ether);
        vm.prank(verifier);
        products.revokeCertification(tokenId, EV, URI);

        assertFalse(catalog.isCleanVerified(id));
        assertFalse(catalog.isAvailable(id));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.ProductNotCertified.selector, tokenId));
        market.buy(id, 1, 10 ether);

        // El vendedor recupera su NFT
        vm.prank(seller);
        catalog.closeListing(id);
        assertEq(products.ownerOf(tokenId), seller);
    }

    function test_CloseListingReturnsNftAndAllowsRelisting() public {
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 10 ether);

        vm.prank(seller);
        catalog.closeListing(id);
        assertEq(products.ownerOf(tokenId), seller);
        assertEq(catalog.listingOfProduct(tokenId), 0);
        assertFalse(catalog.isCleanVerified(id));

        uint256 id2 = _listProduct(tokenId, 11 ether);
        assertEq(id2, 2);
    }

    function test_RevertWhen_EscrowedProductListedAgain() public {
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 10 ether);
        // El NFT ya está en custodia: ya no es del vendedor
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.ProductNotOwned.selector, tokenId));
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, META, true, tokenId);
        assertEq(catalog.listingOfProduct(tokenId), id);
    }

    function test_RevertWhen_ProductClosedWithOpenOrder() public {
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 10 ether);
        uint256 orderId = _buy(id, 1);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.HasOpenOrders.selector, id));
        catalog.closeListing(id);

        // Reembolso sin enviar: el producto vuelve a estar disponible y sigue en custodia
        vm.prank(seller);
        market.refundBySeller(orderId);
        assertEq(catalog.getListing(id).stock, 1);
        assertTrue(catalog.isAvailable(id));
        assertEq(products.ownerOf(tokenId), address(catalog));
    }

    function test_ProductListingStockIsPinnedToOne() public {
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 10 ether);
        vm.startPrank(seller);
        vm.expectRevert(ToKleanCatalog.ProductStockMustBeOne.selector);
        catalog.updateListing(id, 10 ether, 5, META);
        catalog.updateListing(id, 9 ether, 1, META);
        vm.stopPrank();
    }

    function test_CatalogWithoutProductsContract() public {
        ToKleanCatalog plain = new ToKleanCatalog(CircularProductNFT(address(0)), registry, admin);
        vm.prank(seller);
        vm.expectRevert(ToKleanCatalog.ProductsNotConfigured.selector);
        plain.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, META, true, 1);
    }

    // ------------------------------------------------------------------ acceso entre contratos

    function test_RevertWhen_NonMarketplaceCallsReserveOrFinish() public {
        uint256 id = _list(10 ether, 5);
        vm.startPrank(stranger);
        vm.expectRevert(ToKleanCatalog.NotMarketplace.selector);
        catalog.reserve(id, 1, 10 ether, stranger);
        vm.expectRevert(ToKleanCatalog.NotMarketplace.selector);
        catalog.finish(id, 1, stranger, ToKleanCatalog.Outcome.Deliver);
        vm.stopPrank();
    }

    function test_MarketplaceCanOnlyBeSetOnce() public {
        ToKleanCatalog fresh = new ToKleanCatalog(products, registry, admin);
        bytes32 adminRole = fresh.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole
            )
        );
        fresh.setMarketplace(address(market));

        vm.startPrank(admin);
        vm.expectRevert(ToKleanCatalog.ZeroAddress.selector);
        fresh.setMarketplace(address(0));
        fresh.setMarketplace(address(market));
        vm.expectRevert(ToKleanCatalog.MarketplaceAlreadySet.selector);
        fresh.setMarketplace(makeAddr("other"));
        vm.stopPrank();
        assertEq(fresh.marketplace(), address(market));
    }

    function test_RevertWhen_NftOrTokensSentDirectly() public {
        uint256 tokenId = _certifiedProduct(stranger);
        vm.prank(stranger);
        vm.expectRevert(ToKleanCatalog.DirectTransferNotAllowed.selector);
        products.safeTransferFrom(stranger, address(catalog), tokenId);
    }

    // ------------------------------------------------------------------ pausa y parámetros

    function test_PauseBlocksListingAndBuying() public {
        uint256 id = _list(10 ether, 3);
        vm.prank(admin);
        catalog.pause();

        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.buy(id, 1, 10 ether);
        vm.prank(seller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 1 ether, 1, META, false, 0);

        // El vendedor puede cerrar y gestionar sus publicaciones en pausa
        vm.prank(seller);
        catalog.closeListing(id);

        vm.prank(admin);
        catalog.unpause();
        _list(10 ether, 1);
    }

    function test_AcceptedPaymentManagedByParametersRole() public {
        vm.startPrank(admin);
        catalog.setAcceptedPayment(POR, true);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.InvalidPaymentToken.selector, 4));
        catalog.setAcceptedPayment(4, true);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.InvalidPaymentToken.selector, 0));
        catalog.setAcceptedPayment(0, true);
        vm.stopPrank();

        vm.prank(seller);
        catalog.createListing(ToKleanCatalog.Kind.Service, POR, 1 ether, 1, META, false, 0);

        bytes32 role = catalog.PARAMETERS_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        catalog.setAcceptedPayment(TKN, false);
    }

    function test_PauseRequiresPauserRole() public {
        bytes32 role = catalog.PAUSER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        catalog.pause();
    }

    function test_ViewsRevertForUnknownListing() public {
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.UnknownListing.selector, 0));
        catalog.getListing(0);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.UnknownListing.selector, 1));
        catalog.isAvailable(1);
    }

    function test_ConstructorValidations() public {
        vm.expectRevert(ToKleanCatalog.ZeroAddress.selector);
        new ToKleanCatalog(products, registry, address(0));
        vm.expectRevert(ToKleanCatalog.ZeroAddress.selector);
        new ToKleanCatalog(products, ToKleanMerchantRegistryZero(), admin);
    }

    function ToKleanMerchantRegistryZero() internal pure returns (ToKleanMerchantRegistry) {
        return ToKleanMerchantRegistry(address(0));
    }
}
