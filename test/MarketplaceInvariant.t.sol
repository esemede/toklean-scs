// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {MarketplaceBase} from "./MarketplaceBase.t.sol";
import {ToKleanMarketplace} from "../src/marketplace/ToKleanMarketplace.sol";
import {ToKleanCatalog} from "../src/marketplace/ToKleanCatalog.sol";
import {ToKleanMerchantRegistry} from "../src/marketplace/ToKleanMerchantRegistry.sol";

/// @dev Seller contract that rejects every token transfer: it must never block a buyer or an arbiter.
contract HostileSeller {
    ToKleanMarketplace public market;
    ToKleanCatalog public catalog;
    ToKleanMerchantRegistry public registry;

    constructor(ToKleanMarketplace market_, ToKleanCatalog catalog_, ToKleanMerchantRegistry registry_) {
        market = market_;
        catalog = catalog_;
        registry = registry_;
    }

    function apply_() external {
        registry.applyAsMerchant("ipfs://hostile");
    }

    function list(uint256 paymentId, uint128 price) external returns (uint256) {
        return catalog.createListing(ToKleanCatalog.Kind.Service, paymentId, price, 10, "ipfs://l", false, 0);
    }

    function ship(uint256 orderId) external {
        market.markShipped(orderId, "ipfs://t");
    }

    function withdraw(uint256 id) external {
        market.withdraw(address(this), id);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("no tokens");
    }
}

/// @dev Randomised actor driving the marketplace through every state transition.
contract MarketplaceHandler is Test {
    ToKleanMarketplace public m;
    ToKleanCatalog public cat;
    address public arbiter;
    address[] public actors;

    /// @dev Acciones que realmente cambiaron el estado (las demás revierten y se ignoran).
    mapping(bytes32 action => uint256 count) public ok;

    constructor(ToKleanMarketplace m_, ToKleanCatalog cat_, address[] memory actors_, address arbiter_) {
        m = m_;
        cat = cat_;
        actors = actors_;
        arbiter = arbiter_;
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buy(uint256 listingSeed, uint256 buyerSeed, uint32 qty) external {
        uint256 n = cat.listingCount();
        if (n == 0) return;
        uint256 id = (listingSeed % n) + 1;
        address who = _pickActor(buyerSeed);
        uint128 price = cat.getListing(id).price;
        qty = uint32(bound(qty, 1, 3));
        vm.prank(who);
        try m.buy(id, qty, price) {
            ++ok["buy"];
        } catch {}
    }

    /// @dev Primer pedido en el estado pedido, empezando por una posición aleatoria (0 = ninguno).
    function _pick(uint256 seed, ToKleanMarketplace.OrderStatus status) internal view returns (uint256) {
        uint256 n = m.orderCount();
        if (n == 0) return 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = ((seed + i) % n) + 1;
            if (m.getOrder(id).status == status) return id;
        }
        return 0;
    }

    function ship(uint256 seed) external {
        uint256 id = _pick(seed, ToKleanMarketplace.OrderStatus.Paid);
        if (id == 0) return;
        vm.prank(m.getOrder(id).seller);
        try m.markShipped(id, "ipfs://t") {
            ++ok["ship"];
        } catch {}
    }

    function confirm(uint256 seed, bool shipped) external {
        uint256 id = _pick(
            seed, shipped ? ToKleanMarketplace.OrderStatus.Shipped : ToKleanMarketplace.OrderStatus.Paid
        );
        if (id == 0) return;
        vm.prank(m.getOrder(id).buyer);
        try m.confirmReceived(id) {
            ++ok["confirm"];
        } catch {}
    }

    function dispute(uint256 seed) external {
        uint256 id = _pick(seed, ToKleanMarketplace.OrderStatus.Shipped);
        if (id == 0) return;
        vm.prank(m.getOrder(id).buyer);
        try m.openDispute(id, "ipfs://r") {
            ++ok["dispute"];
        } catch {}
    }

    function resolve(uint256 seed, uint16 buyerBps) external {
        uint256 id = _pick(seed, ToKleanMarketplace.OrderStatus.Disputed);
        if (id == 0) return;
        vm.prank(arbiter);
        try m.resolveDispute(id, uint16(bound(buyerBps, 0, 10_000)), false, "ipfs://x") {
            ++ok["resolve"];
        } catch {}
    }

    function sellerRefund(uint256 seed, bool shipped) external {
        uint256 id = _pick(
            seed, shipped ? ToKleanMarketplace.OrderStatus.Shipped : ToKleanMarketplace.OrderStatus.Paid
        );
        if (id == 0) return;
        vm.prank(m.getOrder(id).seller);
        try m.refundBySeller(id) {
            ++ok["sellerRefund"];
        } catch {}
    }

    function timeoutRelease(uint256 seed) external {
        uint256 id = _pick(seed, ToKleanMarketplace.OrderStatus.Shipped);
        if (id == 0) return;
        try m.releaseAfterTimeout(id) {
            ++ok["timeoutRelease"];
        } catch {}
    }

    function refundUnshipped(uint256 seed) external {
        uint256 id = _pick(seed, ToKleanMarketplace.OrderStatus.Paid);
        if (id == 0) return;
        vm.prank(m.getOrder(id).buyer);
        try m.refundUnshipped(id) {
            ++ok["refundUnshipped"];
        } catch {}
    }

    function disputeTimeout(uint256 seed) external {
        uint256 id = _pick(seed, ToKleanMarketplace.OrderStatus.Disputed);
        if (id == 0) return;
        vm.prank(m.getOrder(id).buyer);
        try m.claimDisputeTimeout(id) {
            ++ok["disputeTimeout"];
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 idSeed) external {
        try m.withdraw(_pickActor(actorSeed), (idSeed % 2) + 1) {
            ++ok["withdraw"];
        } catch {}
    }

    function withdrawTreasury(uint256 idSeed) external {
        try m.withdraw(m.treasury(), (idSeed % 2) + 1) {
            ++ok["withdrawTreasury"];
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 20 days));
    }

    function listingCount() external view returns (uint256) {
        return cat.listingCount();
    }
}

contract MarketplaceInvariantTest is StdInvariant, MarketplaceBase {
    MarketplaceHandler handler;
    address[] actors;

    function setUp() public override {
        super.setUp();
        actors.push(seller);
        actors.push(buyer);
        actors.push(makeAddr("buyer2"));
        actors.push(makeAddr("buyer3"));
        _fundBuyer(actors[2], 1_000 ether);
        _fundBuyer(actors[3], 1_000 ether);

        // Dos publicaciones, una en cada medio de pago
        _list(10 ether, 1_000);
        vm.prank(seller);
        catalog.createListing(ToKleanCatalog.Kind.Service, REC, 7 ether, 1_000, META, false, 0);

        // El handler hereda de MarketplaceBase: sólo se usan sus helpers de prank/bound, no su estado propio
        handler = new MarketplaceHandler(market, catalog, actors, arbiter);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.ship.selector;
        selectors[2] = handler.confirm.selector;
        selectors[3] = handler.dispute.selector;
        selectors[4] = handler.resolve.selector;
        selectors[5] = handler.sellerRefund.selector;
        selectors[6] = handler.timeoutRelease.selector;
        selectors[7] = handler.refundUnshipped.selector;
        selectors[8] = handler.disputeTimeout.selector;
        selectors[9] = handler.withdraw.selector;
        selectors[10] = handler.withdrawTreasury.selector;
        selectors[11] = handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Todo token en el contrato es pago en escrow de un pedido abierto o saldo acreditado a alguien.
    function _owed(uint256 id) internal view returns (uint256 owed) {
        for (uint256 i = 0; i < actors.length; ++i) {
            owed += market.claimable(actors[i], id);
        }
        owed += market.claimable(treasury, id);
        uint256 n = market.orderCount();
        for (uint256 i = 1; i <= n; ++i) {
            ToKleanMarketplace.Order memory o = market.getOrder(i);
            if (
                o.paymentId == id
                    && (o.status == ToKleanMarketplace.OrderStatus.Paid
                        || o.status == ToKleanMarketplace.OrderStatus.Shipped
                        || o.status == ToKleanMarketplace.OrderStatus.Disputed)
            ) owed += o.amount;
        }
    }

    function invariant_MarketplaceIsExactlyFullyBacked() public view {
        assertEq(token.balanceOf(address(market), TKN), _owed(TKN), "TKN");
        assertEq(token.balanceOf(address(market), REC), _owed(REC), "REC");
    }

    function afterInvariant() public view {
        console2.log("buy", handler.ok("buy"));
        console2.log("confirm", handler.ok("confirm"));
        console2.log("dispute", handler.ok("dispute"));
        console2.log("resolve", handler.ok("resolve"));
        console2.log("sellerRefund", handler.ok("sellerRefund"));
        console2.log("timeoutRelease", handler.ok("timeoutRelease"));
        console2.log("refundUnshipped", handler.ok("refundUnshipped"));
        console2.log("disputeTimeout", handler.ok("disputeTimeout"));
        console2.log("withdraw", handler.ok("withdraw"));
    }

    function invariant_OpenOrdersMatchListingCounters() public view {
        uint256 n = catalog.listingCount();
        uint256 totalOpen;
        for (uint256 i = 1; i <= n; ++i) {
            totalOpen += catalog.getListing(i).openOrders;
        }
        uint256 open;
        for (uint256 i = 1; i <= market.orderCount(); ++i) {
            ToKleanMarketplace.OrderStatus s = market.getOrder(i).status;
            if (
                s == ToKleanMarketplace.OrderStatus.Paid || s == ToKleanMarketplace.OrderStatus.Shipped
                    || s == ToKleanMarketplace.OrderStatus.Disputed
            ) ++open;
        }
        assertEq(totalOpen, open);
    }
}

contract MarketplaceFuzzTest is MarketplaceBase {
    /// @dev Cualquier reparto de disputa conserva exactamente el pago: comprador + vendedor + tesorería = monto.
    function testFuzz_DisputeSplitConservesFunds(uint96 price, uint8 qty, uint16 buyerBps, uint16 feeBps)
        public
    {
        price = uint96(bound(price, 1, 1_000_000 ether));
        qty = uint8(bound(qty, 1, 10));
        buyerBps = uint16(bound(buyerBps, 0, 10_000));
        feeBps = uint16(bound(feeBps, 0, 1000));
        vm.prank(admin);
        market.setRates(feeBps, POR_BPS);
        _fundBuyer(buyer, uint256(price) * qty);

        vm.prank(seller);
        uint256 id = catalog.createListing(ToKleanCatalog.Kind.Product, TKN, price, qty, META, false, 0);
        vm.prank(buyer);
        uint256 orderId = market.buy(id, qty, price);
        uint256 amount = uint256(price) * qty;
        _ship(orderId);
        vm.prank(buyer);
        market.openDispute(orderId, "ipfs://r");
        vm.prank(arbiter);
        market.resolveDispute(orderId, buyerBps, false, "ipfs://x");

        uint256 total =
            market.claimable(buyer, TKN) + market.claimable(seller, TKN) + market.claimable(treasury, TKN);
        assertEq(total, amount);
        assertEq(market.claimable(buyer, TKN), amount * buyerBps / 10_000);
    }

    /// @dev El pago completo nunca supera el escrow ni deja polvo sin asignar.
    function testFuzz_CompletionConservesFunds(uint96 price, uint8 qty, uint16 feeBps) public {
        price = uint96(bound(price, 1, 1_000_000 ether));
        qty = uint8(bound(qty, 1, 10));
        feeBps = uint16(bound(feeBps, 0, 1000));
        vm.prank(admin);
        market.setRates(feeBps, POR_BPS);
        _fundBuyer(buyer, uint256(price) * qty);
        vm.prank(seller);
        uint256 id = catalog.createListing(ToKleanCatalog.Kind.Product, REC, price, qty, META, false, 0);
        vm.prank(buyer);
        uint256 orderId = market.buy(id, qty, price);
        vm.prank(buyer);
        market.confirmReceived(orderId);

        uint256 amount = uint256(price) * qty;
        assertEq(market.claimable(seller, REC) + market.claimable(treasury, REC), amount);
        assertEq(market.claimable(treasury, REC), amount * feeBps / 10_000);
    }

    function test_HostileSellerCannotBlockBuyerOrArbiter() public {
        HostileSeller hostile = new HostileSeller(market, catalog, registry);
        hostile.apply_();
        vm.prank(merchantAdmin);
        registry.reviewMerchant(address(hostile), true);
        uint256 id = hostile.list(TKN, 10 ether);

        vm.prank(buyer);
        uint256 orderId = market.buy(id, 1, 10 ether);
        hostile.ship(orderId);
        vm.prank(buyer);
        market.confirmReceived(orderId); // no se cae aunque el vendedor rechace tokens

        // Ni siquiera con retiro propio: el contrato hostil sólo se perjudica a sí mismo
        vm.expectRevert();
        hostile.withdraw(TKN);
        assertEq(market.claimable(address(hostile), TKN), 9.8 ether);

        // Disputa con árbitro
        vm.prank(buyer);
        uint256 second = market.buy(id, 1, 10 ether);
        hostile.ship(second);
        vm.prank(buyer);
        market.openDispute(second, "ipfs://r");
        vm.prank(arbiter);
        market.resolveDispute(second, 5000, false, "ipfs://x");
        assertEq(market.claimable(buyer, TKN), 5 ether);
    }
}
