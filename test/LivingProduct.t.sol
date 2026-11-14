// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MarketplaceBase} from "./MarketplaceBase.t.sol";
import {LivingProduct, IProductPassport} from "../src/marketplace/LivingProduct.sol";
import {ToKleanCatalog} from "../src/marketplace/ToKleanCatalog.sol";

contract LivingProductTest is MarketplaceBase {
    LivingProduct living;
    uint256 keyPk = 0xA11CE;
    address claimKey;
    string constant LIVING_URI = "ipfs://bafyliving";

    function setUp() public override {
        super.setUp();
        living = new LivingProduct(IProductPassport(address(products)));
        claimKey = vm.addr(keyPk);
        vm.prank(admin);
        catalog.setLiving(address(living));
    }

    function _sign(uint256 pk, uint256 passportId, address claimer) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", living.claimDigest(passportId, claimer))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Pasaporte certificado -> registrado por el fabricante -> publicado -> comprado -> enviado -> confirmado.
    function _soldProduct() internal returns (uint256 passportId, uint256 listingId, uint256 orderId) {
        passportId = _certifiedProduct(seller);
        vm.prank(manufacturer);
        living.register(passportId, claimKey, LIVING_URI);
        vm.startPrank(seller);
        products.approve(address(catalog), passportId);
        listingId =
            catalog.createListing(ToKleanCatalog.Kind.Product, TKN, 10 ether, 1, META, true, passportId);
        vm.stopPrank();
        orderId = _buy(listingId, 1);
        _ship(orderId);
    }

    function test_SaleSendsPassportToLivingAndBuyerClaims90_10() public {
        (uint256 id,, uint256 orderId) = _soldProduct();
        assertEq(products.ownerOf(id), address(catalog)); // aún en custodia del catálogo
        vm.prank(buyer);
        market.confirmReceived(orderId);

        assertEq(products.ownerOf(id), address(living));
        bytes memory sig = _sign(keyPk, id, buyer);
        vm.prank(buyer);
        living.claim(id, sig);

        assertEq(living.balanceOf(buyer, id), 90);
        assertEq(living.balanceOf(manufacturer, id), 10);
        assertEq(living.uri(id), LIVING_URI);
        assertTrue(living.getUnit(id).claimed);
    }

    function test_RevertWhen_ClaimingBeforeDeliveryOrWithWrongSignatureOrTwice() public {
        (uint256 id,, uint256 orderId) = _soldProduct();
        bytes memory good = _sign(keyPk, id, buyer);
        bytes memory wrong = _sign(0xB0B, id, buyer);

        // el producto todavía no se entregó
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivingProduct.NotSoldYet.selector, id));
        living.claim(id, good);

        vm.prank(buyer);
        market.confirmReceived(orderId);

        // firma de otra llave
        vm.prank(buyer);
        vm.expectRevert(LivingProduct.BadClaimSignature.selector);
        living.claim(id, wrong);

        vm.prank(buyer);
        living.claim(id, good);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivingProduct.AlreadyClaimed.selector, id));
        living.claim(id, good);
    }

    function test_FrontRunnerCannotReuseSignatureForAnotherAccount() public {
        (uint256 id,, uint256 orderId) = _soldProduct();
        vm.prank(buyer);
        market.confirmReceived(orderId);
        bytes memory sig = _sign(keyPk, id, buyer);
        vm.prank(stranger);
        vm.expectRevert(LivingProduct.BadClaimSignature.selector);
        living.claim(id, sig);
    }

    function test_ProducerSharesAreLockedAndBuyerSharesMove() public {
        (uint256 id,, uint256 orderId) = _soldProduct();
        vm.prank(buyer);
        market.confirmReceived(orderId);
        bytes memory sig = _sign(keyPk, id, buyer);
        vm.prank(buyer);
        living.claim(id, sig);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(LivingProduct.ProducerSharesLocked.selector, id));
        living.safeTransferFrom(manufacturer, stranger, id, 1, "");

        vm.prank(buyer);
        living.safeTransferFrom(buyer, stranger, id, 90, "");
        assertEq(living.balanceOf(stranger, id), 90);
        assertEq(living.balanceOf(buyer, id), 0);
    }

    function test_HoldersAddTraceAndProducerRecoveryClosesTheLoop() public {
        (uint256 id,, uint256 orderId) = _soldProduct();
        vm.prank(buyer);
        market.confirmReceived(orderId);
        bytes memory sig = _sign(keyPk, id, buyer);
        vm.prank(buyer);
        living.claim(id, sig);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LivingProduct.NotHolder.selector, id, stranger));
        living.addTrace(id, LivingProduct.TraceKind.Note, EV, URI);

        vm.prank(buyer);
        living.addTrace(id, LivingProduct.TraceKind.Repair, EV, URI);
        assertFalse(living.getUnit(id).recovered);

        // un Recovery del comprador no cuenta: sólo el productor cierra el ciclo
        vm.prank(buyer);
        living.addTrace(id, LivingProduct.TraceKind.Recovery, EV, URI);
        assertFalse(living.getUnit(id).recovered);

        vm.prank(manufacturer);
        living.addTrace(id, LivingProduct.TraceKind.Recovery, EV, URI);
        assertTrue(living.getUnit(id).recovered);
        assertEq(living.getUnit(id).traceCount, 3);
    }

    function test_OnlyTheManufacturerRegistersOnce() public {
        uint256 id = _certifiedProduct(seller);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(LivingProduct.NotProducer.selector, id, seller));
        living.register(id, claimKey, LIVING_URI);

        vm.startPrank(manufacturer);
        vm.expectRevert(LivingProduct.ZeroAddress.selector);
        living.register(id, address(0), LIVING_URI);
        vm.expectRevert(LivingProduct.EmptyUri.selector);
        living.register(id, claimKey, "");
        living.register(id, claimKey, LIVING_URI);
        vm.expectRevert(abi.encodeWithSelector(LivingProduct.AlreadyRegistered.selector, id));
        living.register(id, claimKey, LIVING_URI);
        living.setUri(id, "ipfs://nuevo");
        vm.stopPrank();
        assertEq(living.uri(id), "ipfs://nuevo");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LivingProduct.NotProducer.selector, id, stranger));
        living.setUri(id, "ipfs://robado");
    }

    function test_UnregisteredUnitCannotBeClaimed() public {
        uint256 id = _certifiedProduct(seller);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(LivingProduct.NotRegistered.selector, id));
        living.claim(id, "");
    }

    function test_DeployedSizeFitsTheGasBudget() public view {
        assertLt(address(living).code.length, 10_000, "LivingProduct");
    }

    function test_LivingCanBeSetOnlyOnce() public {
        vm.prank(admin);
        vm.expectRevert(ToKleanCatalog.LivingAlreadySet.selector);
        catalog.setLiving(address(0xBEEF));
    }
}
