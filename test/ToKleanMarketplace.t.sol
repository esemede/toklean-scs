// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MarketplaceBase} from "./MarketplaceBase.t.sol";
import {ToKleanMarketplace} from "../src/marketplace/ToKleanMarketplace.sol";
import {ToKleanCatalog} from "../src/marketplace/ToKleanCatalog.sol";
import {ToKleanMerchantRegistry} from "../src/marketplace/ToKleanMerchantRegistry.sol";

contract ToKleanMarketplaceTest is MarketplaceBase {
    // ------------------------------------------------------------------ compra, escrow y liberación

    function test_BuyHoldsPaymentInEscrow() public {
        uint256 id = _list(10 ether, 5);
        uint256 orderId = _buy(id, 3);

        assertEq(token.balanceOf(buyer, TKN), 1_000 ether - 30 ether);
        assertEq(token.balanceOf(address(market), TKN), 30 ether);
        ToKleanCatalog.Listing memory l = catalog.getListing(id);
        assertEq(l.stock, 2);
        assertEq(l.openOrders, 1);

        ToKleanMarketplace.Order memory o = market.getOrder(orderId);
        assertEq(o.buyer, buyer);
        assertEq(o.seller, seller);
        assertEq(o.amount, 30 ether);
        assertEq(o.qty, 3);
        assertEq(o.feeBps, FEE);
        assertEq(uint8(o.status), uint8(ToKleanMarketplace.OrderStatus.Paid));
        assertEq(o.deadline, block.timestamp + 7 days);
        assertEq(market.orderCount(), 1);
    }

    function test_ConfirmReceivedCreditsSellerAndTreasury() public {
        uint256 id = _list(100 ether, 1);
        uint256 orderId = _buy(id, 1);
        _ship(orderId);
        vm.prank(buyer);
        market.confirmReceived(orderId);

        assertEq(market.claimable(seller, TKN), 98 ether);
        assertEq(market.claimable(treasury, TKN), 2 ether);
        assertEq(registry.getMerchant(seller).completedSales, 1);
        // Los fondos siguen en el contrato hasta retirar
        assertEq(token.balanceOf(address(market), TKN), 100 ether);

        // Cualquiera ejecuta el retiro; el dinero va a la cuenta dueña
        vm.prank(stranger);
        market.withdraw(seller, TKN);
        vm.prank(stranger);
        market.withdraw(treasury, TKN);
        assertEq(token.balanceOf(seller, TKN), 98 ether);
        assertEq(token.balanceOf(treasury, TKN), 2 ether);
        assertEq(token.balanceOf(address(market), TKN), 0);

        vm.expectRevert(ToKleanMarketplace.NothingToWithdraw.selector);
        market.withdraw(seller, TKN);
    }

    function test_ServicesCanBeConfirmedWithoutShipping() public {
        vm.prank(seller);
        uint256 id = catalog.createListing(ToKleanCatalog.Kind.Service, REC, 20 ether, 10, META, false, 0);
        vm.prank(buyer);
        uint256 orderId = market.buy(id, 1, 20 ether);
        vm.prank(buyer);
        market.confirmReceived(orderId);
        assertEq(market.claimable(seller, REC), 19.6 ether);
        assertEq(market.claimable(treasury, REC), 0.4 ether);
    }

    function test_ReleaseAfterTimeout() public {
        uint256 orderId = _buy(_list(50 ether, 1), 1);
        _ship(orderId);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.TooEarly.selector, orderId, uint64(block.timestamp + 14 days)
            )
        );
        market.releaseAfterTimeout(orderId);

        vm.warp(block.timestamp + 14 days);
        vm.prank(stranger);
        market.releaseAfterTimeout(orderId);
        assertEq(market.claimable(seller, TKN), 49 ether);
    }

    function test_RefundUnshippedAfterWindow() public {
        uint256 id = _list(50 ether, 4);
        uint256 orderId = _buy(id, 2);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.TooEarly.selector, orderId, uint64(block.timestamp + 7 days)
            )
        );
        market.refundUnshipped(orderId);

        vm.warp(block.timestamp + 7 days);
        vm.prank(buyer);
        market.refundUnshipped(orderId);

        assertEq(market.claimable(buyer, TKN), 100 ether);
        ToKleanCatalog.Listing memory l = catalog.getListing(id);
        assertEq(l.stock, 4); // reabastecido
        assertEq(l.openOrders, 0);
        market.withdraw(buyer, TKN);
        assertEq(token.balanceOf(buyer, TKN), 1_000 ether);
    }

    function test_SellerCanRefundVoluntarily() public {
        uint256 id = _list(50 ether, 1);
        uint256 orderId = _buy(id, 1);
        vm.prank(seller);
        market.refundBySeller(orderId);
        assertEq(market.claimable(buyer, TKN), 50 ether);
        assertEq(catalog.getListing(id).stock, 1);
    }

    function test_SellerRefundAfterShippingDoesNotRestock() public {
        uint256 id = _list(50 ether, 1);
        uint256 orderId = _buy(id, 1);
        _ship(orderId);
        vm.prank(seller);
        market.refundBySeller(orderId);
        assertEq(market.claimable(buyer, TKN), 50 ether);
        assertEq(catalog.getListing(id).stock, 0);
    }

    function test_RevertWhen_BuyerRefundsAfterShipping() public {
        uint256 orderId = _buy(_list(50 ether, 1), 1);
        _ship(orderId);
        vm.warp(block.timestamp + 8 days);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.InvalidOrderStatus.selector,
                orderId,
                ToKleanMarketplace.OrderStatus.Shipped
            )
        );
        market.refundUnshipped(orderId);
    }

    function test_RevertWhen_OrderActionsByWrongAccountOrStatus() public {
        uint256 orderId = _buy(_list(50 ether, 1), 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.NotOrderSeller.selector, orderId));
        market.markShipped(orderId, "ipfs://t");
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.NotOrderBuyer.selector, orderId));
        market.confirmReceived(orderId);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.NotOrderSeller.selector, orderId));
        market.refundBySeller(orderId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.InvalidUri.selector));
        market.markShipped(orderId, "");

        _ship(orderId);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.InvalidOrderStatus.selector,
                orderId,
                ToKleanMarketplace.OrderStatus.Shipped
            )
        );
        market.markShipped(orderId, "ipfs://t");
    }

    function test_RevertWhen_CompletedOrderIsFinalised() public {
        uint256 orderId = _buy(_list(50 ether, 1), 1);
        vm.startPrank(buyer);
        market.confirmReceived(orderId);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.InvalidOrderStatus.selector,
                orderId,
                ToKleanMarketplace.OrderStatus.Completed
            )
        );
        market.confirmReceived(orderId);
        vm.stopPrank();
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.InvalidOrderStatus.selector,
                orderId,
                ToKleanMarketplace.OrderStatus.Completed
            )
        );
        market.refundBySeller(orderId);
    }

    function test_RevertWhen_BuyChecksFail() public {
        uint256 id = _list(10 ether, 2);
        vm.startPrank(buyer);
        vm.expectRevert(ToKleanMarketplace.ZeroAmount.selector);
        market.buy(id, 0, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.InsufficientStock.selector, 3, 2));
        market.buy(id, 3, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.PriceTooHigh.selector, 10 ether, 9 ether));
        market.buy(id, 1, 9 ether);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.UnknownListing.selector, 7));
        market.buy(7, 1, 10 ether);
        vm.stopPrank();

        vm.prank(seller);
        vm.expectRevert(ToKleanCatalog.SelfPurchase.selector);
        market.buy(id, 1, 10 ether);
    }

    function test_RevertWhen_BuyerHasNoFundsOrApproval() public {
        uint256 id = _list(10 ether, 2);
        vm.prank(stranger);
        vm.expectRevert();
        market.buy(id, 1, 10 ether);
        // La reserva de stock se revierte junto con el pago fallido
        assertEq(catalog.getListing(id).stock, 2);
        assertEq(market.orderCount(), 0);
    }

    function test_PriceChangeCannotFrontRunBuyer() public {
        uint256 id = _list(10 ether, 2);
        vm.prank(seller);
        catalog.updateListing(id, 50 ether, 2, META);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ToKleanCatalog.PriceTooHigh.selector, 50 ether, 10 ether));
        market.buy(id, 1, 10 ether);
    }

    function test_SuspendedMerchantOpenOrdersContinue() public {
        uint256 id = _list(10 ether, 5);
        uint256 orderId = _buy(id, 1);
        vm.prank(merchantAdmin);
        registry.setSuspended(seller, true);

        _ship(orderId);
        vm.prank(buyer);
        market.confirmReceived(orderId);
        assertGt(market.claimable(seller, TKN), 0);
    }

    // ------------------------------------------------------------------ productos limpios

    function test_CleanProductSaleDeliversNftAndRewardsPor() public {
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 200 ether);
        uint256 orderId = _buy(id, 1);
        _ship(orderId);
        vm.prank(buyer);
        market.confirmReceived(orderId);

        // El pasaporte viaja al comprador y la publicación se cierra
        assertEq(products.ownerOf(tokenId), buyer);
        ToKleanCatalog.Listing memory l = catalog.getListing(id);
        assertEq(uint8(l.status), uint8(ToKleanCatalog.Status.Closed));
        assertFalse(catalog.isAvailable(id));
        assertEq(catalog.listingOfProduct(tokenId), 0);
        // POR = 10 % del pago
        assertEq(token.balanceOf(buyer, POR), 20 ether);
        assertEq(market.claimable(seller, TKN), 196 ether);
    }

    function test_NoPorForGenericListings() public {
        uint256 orderId = _buy(_list(100 ether, 1), 1);
        vm.prank(buyer);
        market.confirmReceived(orderId);
        assertEq(token.balanceOf(buyer, POR), 0);
    }

    function test_PorFailureDoesNotBlockPayment() public {
        bytes32 minter = token.MINTER_ROLE();
        vm.prank(admin);
        token.revokeRole(minter, address(market));

        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 200 ether);
        uint256 orderId = _buy(id, 1);
        vm.prank(buyer);
        market.confirmReceived(orderId);

        assertEq(token.balanceOf(buyer, POR), 0);
        assertEq(market.claimable(seller, TKN), 196 ether);
        assertEq(products.ownerOf(tokenId), buyer);
    }

    // ------------------------------------------------------------------ disputas

    function test_DisputeResolvedWithSplit() public {
        uint256 orderId = _buy(_list(100 ether, 1), 1);
        _ship(orderId);

        vm.prank(buyer);
        market.openDispute(orderId, "ipfs://bafyreason");
        assertEq(uint8(market.getOrder(orderId).status), uint8(ToKleanMarketplace.OrderStatus.Disputed));

        vm.prank(arbiter);
        market.resolveDispute(orderId, 3000, false, "ipfs://bafyruling"); // 30 % al comprador

        assertEq(market.claimable(buyer, TKN), 30 ether);
        // vendedor: 70 - 2 % de 70 = 68,6; tesorería: 1,4
        assertEq(market.claimable(seller, TKN), 68.6 ether);
        assertEq(market.claimable(treasury, TKN), 1.4 ether);
        assertEq(uint8(market.getOrder(orderId).status), uint8(ToKleanMarketplace.OrderStatus.Resolved));
    }

    function test_DisputeFullRefundForBuyerHasNoFee() public {
        uint256 orderId = _buy(_list(100 ether, 1), 1);
        _ship(orderId);
        vm.prank(buyer);
        market.openDispute(orderId, "ipfs://bafyreason");
        vm.prank(arbiter);
        market.resolveDispute(orderId, 10_000, false, "ipfs://bafyruling");
        assertEq(market.claimable(buyer, TKN), 100 ether);
        assertEq(market.claimable(seller, TKN), 0);
        assertEq(market.claimable(treasury, TKN), 0);
    }

    function test_DisputeCanSendNftToBuyer() public {
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 100 ether);
        uint256 orderId = _buy(id, 1);
        _ship(orderId);
        vm.prank(buyer);
        market.openDispute(orderId, "ipfs://bafyreason");
        vm.prank(arbiter);
        market.resolveDispute(orderId, 2000, true, "ipfs://bafyruling");
        assertEq(products.ownerOf(tokenId), buyer);
        assertEq(uint8(catalog.getListing(id).status), uint8(ToKleanCatalog.Status.Closed));
    }

    function test_DisputeKeepsNftInCustodyWhenReturned() public {
        uint256 tokenId = _certifiedProduct(seller);
        uint256 id = _listProduct(tokenId, 100 ether);
        uint256 orderId = _buy(id, 1);
        _ship(orderId);
        vm.prank(buyer);
        market.openDispute(orderId, "ipfs://bafyreason");
        vm.prank(arbiter);
        market.resolveDispute(orderId, 10_000, false, "ipfs://bafyruling");

        assertEq(products.ownerOf(tokenId), address(catalog));
        assertEq(catalog.getListing(id).stock, 1);
        assertTrue(catalog.isAvailable(id));
    }

    function test_RevertWhen_DisputeRulesBroken() public {
        uint256 orderId = _buy(_list(100 ether, 1), 1);

        // Sin enviar no se puede disputar (se usa el reembolso por falta de envío)
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.InvalidOrderStatus.selector, orderId, ToKleanMarketplace.OrderStatus.Paid
            )
        );
        market.openDispute(orderId, "ipfs://r");

        _ship(orderId);
        // Sólo el comprador
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.NotOrderBuyer.selector, orderId));
        market.openDispute(orderId, "ipfs://r");
        vm.prank(buyer);
        vm.expectRevert(ToKleanMarketplace.InvalidUri.selector);
        market.openDispute(orderId, "");

        // Tarde: ya venció la ventana de confirmación
        vm.warp(block.timestamp + 14 days);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanMarketplace.TooLate.selector, orderId, uint64(block.timestamp))
        );
        market.openDispute(orderId, "ipfs://r");
    }

    function test_RevertWhen_NonArbiterResolvesOrBadBps() public {
        uint256 orderId = _buy(_list(100 ether, 1), 1);
        _ship(orderId);
        vm.prank(buyer);
        market.openDispute(orderId, "ipfs://r");

        bytes32 role = market.ARBITER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        market.resolveDispute(orderId, 5000, false, "ipfs://r");

        vm.startPrank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.InvalidBps.selector, 10_001));
        market.resolveDispute(orderId, 10_001, false, "ipfs://r");
        vm.expectRevert(ToKleanMarketplace.InvalidUri.selector);
        market.resolveDispute(orderId, 5000, false, "");
        vm.stopPrank();
    }

    function test_RevertWhen_ResolvingAnOrderThatIsNotDisputed() public {
        uint256 orderId = _buy(_list(100 ether, 1), 1);
        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.InvalidOrderStatus.selector, orderId, ToKleanMarketplace.OrderStatus.Paid
            )
        );
        market.resolveDispute(orderId, 5000, false, "ipfs://r");
    }

    function test_DisputeTimeoutRefundsBuyer() public {
        uint256 orderId = _buy(_list(100 ether, 1), 1);
        _ship(orderId);
        vm.prank(buyer);
        market.openDispute(orderId, "ipfs://r");

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.TooEarly.selector, orderId, uint64(block.timestamp + 30 days)
            )
        );
        market.claimDisputeTimeout(orderId);

        vm.warp(block.timestamp + 30 days);
        vm.prank(buyer);
        market.claimDisputeTimeout(orderId);
        assertEq(market.claimable(buyer, TKN), 100 ether);
        assertEq(uint8(market.getOrder(orderId).status), uint8(ToKleanMarketplace.OrderStatus.Refunded));
    }

    // ------------------------------------------------------------------ valoraciones

    function test_RateCompletedOrderOnce() public {
        uint256 orderId = _buy(_list(10 ether, 2), 1);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanMarketplace.InvalidOrderStatus.selector, orderId, ToKleanMarketplace.OrderStatus.Paid
            )
        );
        market.rate(orderId, 5);

        vm.startPrank(buyer);
        market.confirmReceived(orderId);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.InvalidScore.selector, 0));
        market.rate(orderId, 0);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.InvalidScore.selector, 6));
        market.rate(orderId, 6);
        market.rate(orderId, 4);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.AlreadyRated.selector, orderId));
        market.rate(orderId, 5);
        vm.stopPrank();

        uint256 second = _buy(1, 1);
        vm.startPrank(buyer);
        market.confirmReceived(second);
        market.rate(second, 5);
        vm.stopPrank();

        (uint256 avg, uint256 count) = registry.ratingOf(seller);
        assertEq(count, 2);
        assertEq(avg, 450);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.NotOrderBuyer.selector, orderId));
        market.rate(orderId, 1);
    }

    // ------------------------------------------------------------------ pausa (en el catálogo) y parámetros

    function test_PauseDoesNotBlockSettlementOrWithdrawals() public {
        uint256 id = _list(10 ether, 3);
        uint256 orderId = _buy(id, 1);
        _ship(orderId);

        vm.prank(admin);
        catalog.pause();

        // Cerrar pedidos y retirar sigue funcionando
        vm.prank(buyer);
        market.confirmReceived(orderId);
        market.withdraw(seller, TKN);
        assertGt(token.balanceOf(seller, TKN), 0);

        // También los reembolsos y las disputas
        vm.prank(buyer);
        vm.expectRevert(); // compra bloqueada
        market.buy(id, 1, 10 ether);
    }

    function test_RatesAndWindowsOnlyByRoleAndWithinBounds() public {
        vm.startPrank(admin);
        market.setRates(500, 2000);
        assertEq(market.feeBps(), 500);
        assertEq(market.porRewardBps(), 2000);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.FeeTooHigh.selector, 1001));
        market.setRates(1001, 0);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.RewardTooHigh.selector, 5001));
        market.setRates(0, 5001);
        vm.expectRevert(ToKleanMarketplace.ZeroAddress.selector);
        market.setTreasury(address(0));
        market.setTreasury(makeAddr("newTreasury"));
        market.setWindows(2 days, 5 days, 10 days);
        vm.expectRevert(ToKleanMarketplace.InvalidWindow.selector);
        market.setWindows(0, 5 days, 10 days);
        vm.expectRevert(ToKleanMarketplace.InvalidWindow.selector);
        market.setWindows(2 days, 2 days, 10 days);
        vm.expectRevert(ToKleanMarketplace.InvalidWindow.selector);
        market.setWindows(2 days, 5 days, 91 days);
        vm.stopPrank();

        bytes32 role = market.PARAMETERS_ROLE();
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        market.setRates(0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        market.setTreasury(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        market.setWindows(2 days, 5 days, 10 days);
        vm.stopPrank();
    }

    function test_RateChangeDoesNotAffectOpenOrders() public {
        uint256 id = _list(100 ether, 1);
        uint256 orderId = _buy(id, 1);
        vm.prank(admin);
        market.setRates(1000, 0);
        vm.prank(buyer);
        market.confirmReceived(orderId);
        assertEq(market.claimable(treasury, TKN), 2 ether); // comisión vigente al comprar
    }

    function test_WindowChangeAppliesToNewOrdersOnly() public {
        uint256 id = _list(10 ether, 2);
        uint256 first = _buy(id, 1);
        vm.prank(admin);
        market.setWindows(2 days, 5 days, 10 days);
        uint256 second = _buy(id, 1);
        assertEq(market.getOrder(first).deadline, block.timestamp + 7 days);
        assertEq(market.getOrder(second).deadline, block.timestamp + 2 days);
    }

    // ------------------------------------------------------------------ recepción de tokens y vistas

    function test_RevertWhen_TokensSentDirectly() public {
        vm.prank(admin);
        token.mint(stranger, TKN, 5 ether);
        vm.prank(stranger);
        vm.expectRevert(ToKleanMarketplace.DirectTransferNotAllowed.selector);
        token.safeTransferFrom(stranger, address(market), TKN, 5 ether, "");

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = TKN;
        amounts[0] = 1 ether;
        vm.prank(stranger);
        vm.expectRevert(ToKleanMarketplace.DirectTransferNotAllowed.selector);
        token.safeBatchTransferFrom(stranger, address(market), ids, amounts, "");
    }

    function test_ViewsRevertForUnknownOrder() public {
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.UnknownOrder.selector, 0));
        market.getOrder(0);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.UnknownOrder.selector, 1));
        market.getOrder(1);
    }

    function test_ConstructorValidations() public {
        vm.expectRevert(ToKleanMarketplace.ZeroAddress.selector);
        new ToKleanMarketplace(token, catalog, registry, address(0), treasury, FEE, POR_BPS);
        vm.expectRevert(ToKleanMarketplace.ZeroAddress.selector);
        new ToKleanMarketplace(token, catalog, registry, admin, address(0), FEE, POR_BPS);
        vm.expectRevert(ToKleanMarketplace.ZeroAddress.selector);
        new ToKleanMarketplace(token, ToKleanCatalog(address(0)), registry, admin, treasury, FEE, POR_BPS);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.FeeTooHigh.selector, 1001));
        new ToKleanMarketplace(token, catalog, registry, admin, treasury, 1001, POR_BPS);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMarketplace.RewardTooHigh.selector, 5001));
        new ToKleanMarketplace(token, catalog, registry, admin, treasury, FEE, 5001);
    }

    // ------------------------------------------------------------------ presupuesto de gas de despliegue

    /// @dev En Sepolia hoy se pagan ~1.600 de gas por byte de código y el tope por transacción es 16,7 M: cada
    ///      contrato del marketplace debe quedar bajo ~10 KB para poder desplegarse. Este test avisa antes de que un
    ///      cambio lo rompa (mide el código desplegado, no el initcode).
    function test_DeployedSizeFitsTheGasBudget() public view {
        assertLt(address(market).code.length, 10_000, "ToKleanMarketplace");
        assertLt(address(catalog).code.length, 10_000, "ToKleanCatalog");
        assertLt(address(registry).code.length, 10_000, "ToKleanMerchantRegistry");
    }
}
