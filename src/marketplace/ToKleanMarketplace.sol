// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ToKleanToken} from "../token/ToKleanToken.sol";
import {ToKleanCatalog} from "./ToKleanCatalog.sol";
import {ToKleanMerchantRegistry} from "./ToKleanMerchantRegistry.sol";

/// @title ToKleanMarketplace
/// @notice Pedidos del marketplace sostenible de ToKlean: el comprador paga con tokens ERC-1155 de la economía
///         (TKN/REC) y el pago queda en custodia (escrow) hasta que confirma la recepción.
/// @dev Forma parte de tres contratos: `ToKleanMerchantRegistry` (comercios y reputación), `ToKleanCatalog`
///      (publicaciones, stock y custodia del NFT de producto limpio) y éste (pedidos, escrow, disputas y pagos).
///      Dividido en piezas de menos de ~10 KB porque en Sepolia hoy se pagan ~1.600 de gas por byte de código y el
///      tope por transacción es 16,7 M.
///
///      - **Escrow**: Pagada -> Enviada -> Completada. El comprador confirma la recepción o, pasada la ventana de
///        confirmación, cualquiera puede liberar el pago al vendedor.
///      - **Garantías al comprador**: si el vendedor no envía dentro de `shipWindow` el comprador se reembolsa solo;
///        puede abrir una disputa mientras el pedido esté enviado y antes de la liberación automática.
///      - **Disputas**: las resuelve el `ARBITER_ROLE` repartiendo el pago. Si nadie resuelve en
///        `resolutionWindow`, el comprador recupera todo (nunca quedan fondos bloqueados por inacción).
///      - **Pagos pull**: vendedores, compradores (reembolsos) y tesorería acumulan `claimable` y retiran con
///        `withdraw`. Una cuenta que rechaza tokens no puede bloquear la liberación de un pedido ni una resolución.
///      - **POR**: al completarse la venta de un producto limpio certificado se emite POR (Prueba de Reciclaje) al
///        comprador, si este contrato tiene `MINTER_ROLE`. Un fallo al emitir nunca bloquea el cobro.
///      - La pausa vive en el catálogo: bloquea publicar y comprar; liberar, reembolsar, disputar y retirar siguen.
contract ToKleanMarketplace is ERC1155Holder, AccessControl, ReentrancyGuard {
    /// @notice Cambia comisión, tesorería y ventanas (idealmente la gobernanza).
    bytes32 public constant PARAMETERS_ROLE = keccak256("PARAMETERS_ROLE");
    /// @notice Resuelve disputas (multisig de emergencia / comité).
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");

    uint16 private constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1000; // 10 %
    uint16 public constant MAX_POR_BPS = 5000; // 50 %
    uint256 private constant MAX_URI_LENGTH = 256;
    uint256 private constant POR_ID = 3;

    ToKleanToken public immutable token;
    ToKleanCatalog public immutable catalog;
    ToKleanMerchantRegistry public immutable registry;

    uint16 public feeBps;
    uint16 public porRewardBps;
    address public treasury;
    uint32 public shipWindow = 7 days;
    uint32 public confirmWindow = 14 days;
    uint32 public resolutionWindow = 30 days;

    enum OrderStatus {
        Paid,
        Shipped,
        Completed,
        Refunded,
        Disputed,
        Resolved
    }

    struct Order {
        uint256 listingId;
        address buyer;
        address seller;
        uint256 amount;
        uint32 qty;
        uint16 feeBps;
        uint16 porBps;
        uint8 paymentId;
        OrderStatus status;
        bool rated;
        /// @dev Paid: límite de envío; Shipped: liberación automática; Disputed: límite de resolución.
        uint64 deadline;
    }

    Order[] private _orders; // id = índice + 1
    mapping(address account => mapping(uint256 id => uint256 amount)) public claimable;

    event OrderCreated(
        uint256 indexed orderId,
        uint256 indexed listingId,
        address indexed buyer,
        address seller,
        uint256 qty,
        uint256 amount,
        uint256 paymentId
    );
    event OrderShipped(uint256 indexed orderId, string trackingURI);
    event OrderCompleted(uint256 indexed orderId, uint256 sellerAmount, uint256 fee);
    event OrderRefunded(uint256 indexed orderId, uint256 amount);
    event DisputeOpened(uint256 indexed orderId, string reasonURI);
    event DisputeResolved(uint256 indexed orderId, uint16 buyerBps, bool nftToBuyer, string rulingURI);
    event Rated(uint256 indexed orderId, address indexed seller, uint8 score);
    event Withdrawn(address indexed account, uint256 indexed id, uint256 amount);
    /// @dev `minted` false: el POR no se pudo emitir (sin MINTER_ROLE o token en pausa) pero el pago se cobró igual.
    event PorRewarded(uint256 indexed orderId, address indexed buyer, uint256 amount, bool minted);
    event RatesUpdated(uint16 feeBps, uint16 porRewardBps);
    event TreasuryUpdated(address treasury);
    event WindowsUpdated(uint32 shipWindow, uint32 confirmWindow, uint32 resolutionWindow);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh(uint16 feeBps);
    error RewardTooHigh(uint16 bps);
    error InvalidWindow();
    error InvalidUri();
    error InvalidScore(uint8 score);
    error AlreadyRated(uint256 orderId);
    error InvalidBps(uint16 bps);
    error UnknownOrder(uint256 orderId);
    error NotOrderSeller(uint256 orderId);
    error NotOrderBuyer(uint256 orderId);
    error InvalidOrderStatus(uint256 orderId, OrderStatus current);
    error TooEarly(uint256 orderId, uint64 deadline);
    error TooLate(uint256 orderId, uint64 deadline);
    error NothingToWithdraw();
    error DirectTransferNotAllowed();

    constructor(
        ToKleanToken token_,
        ToKleanCatalog catalog_,
        ToKleanMerchantRegistry registry_,
        address admin,
        address treasury_,
        uint16 feeBps_,
        uint16 porRewardBps_
    ) {
        if (
            address(token_) == address(0) || address(catalog_) == address(0)
                || address(registry_) == address(0) || admin == address(0) || treasury_ == address(0)
        ) revert ZeroAddress();
        token = token_;
        catalog = catalog_;
        registry = registry_;
        treasury = treasury_;
        _setRates(feeBps_, porRewardBps_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARAMETERS_ROLE, admin);
        _grantRole(ARBITER_ROLE, admin);
        emit TreasuryUpdated(treasury_);
    }

    // ================================================================== compra y entrega

    /// @notice Compra `qty` unidades; el pago queda en escrow. Requiere `setApprovalForAll(marketplace, true)` en el
    ///         token. `maxUnitPrice` protege contra un cambio de precio entre la firma y la ejecución.
    function buy(uint256 listingId, uint32 qty, uint256 maxUnitPrice)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (qty == 0) revert ZeroAmount();
        (address seller, uint128 price, uint8 paymentId, bool hasProduct) =
            catalog.reserve(listingId, qty, maxUnitPrice, msg.sender);

        uint256 amount = uint256(price) * qty; // < 2^160: no desborda

        _orders.push(
            Order({
                listingId: listingId,
                buyer: msg.sender,
                seller: seller,
                amount: amount,
                qty: qty,
                feeBps: feeBps,
                porBps: hasProduct ? porRewardBps : 0,
                paymentId: paymentId,
                status: OrderStatus.Paid,
                rated: false,
                deadline: uint64(block.timestamp) + shipWindow
            })
        );
        orderId = _orders.length;

        emit OrderCreated(orderId, listingId, msg.sender, seller, qty, amount, paymentId);
        token.safeTransferFrom(msg.sender, address(this), paymentId, amount, "");
    }

    /// @notice El vendedor informa el envío (o la prestación del servicio). Inicia la ventana de confirmación.
    function markShipped(uint256 orderId, string calldata trackingURI) external {
        Order storage o = _order(orderId);
        if (o.seller != msg.sender) revert NotOrderSeller(orderId);
        if (o.status != OrderStatus.Paid) revert InvalidOrderStatus(orderId, o.status);
        _checkUri(trackingURI);
        o.status = OrderStatus.Shipped;
        o.deadline = uint64(block.timestamp) + confirmWindow;
        emit OrderShipped(orderId, trackingURI);
    }

    /// @notice El comprador confirma la recepción: el pago se acredita al vendedor (menos la comisión).
    function confirmReceived(uint256 orderId) external nonReentrant {
        Order storage o = _order(orderId);
        if (o.buyer != msg.sender) revert NotOrderBuyer(orderId);
        if (o.status != OrderStatus.Paid && o.status != OrderStatus.Shipped) {
            revert InvalidOrderStatus(orderId, o.status);
        }
        _complete(orderId, o);
    }

    /// @notice Cualquiera libera el pago al vendedor cuando venció la ventana de confirmación sin disputa.
    function releaseAfterTimeout(uint256 orderId) external nonReentrant {
        Order storage o = _order(orderId);
        if (o.status != OrderStatus.Shipped) revert InvalidOrderStatus(orderId, o.status);
        if (block.timestamp < o.deadline) revert TooEarly(orderId, o.deadline);
        _complete(orderId, o);
    }

    /// @notice El comprador se reembolsa si el vendedor no envió dentro de `shipWindow`.
    function refundUnshipped(uint256 orderId) external {
        Order storage o = _order(orderId);
        if (o.buyer != msg.sender) revert NotOrderBuyer(orderId);
        if (o.status != OrderStatus.Paid) revert InvalidOrderStatus(orderId, o.status);
        if (block.timestamp < o.deadline) revert TooEarly(orderId, o.deadline);
        _refund(orderId, o, ToKleanCatalog.Outcome.Restock);
    }

    /// @notice El vendedor devuelve voluntariamente todo el pago antes de completarse el pedido.
    function refundBySeller(uint256 orderId) external {
        Order storage o = _order(orderId);
        if (o.seller != msg.sender) revert NotOrderSeller(orderId);
        if (o.status != OrderStatus.Paid && o.status != OrderStatus.Shipped) {
            revert InvalidOrderStatus(orderId, o.status);
        }
        _refund(
            orderId,
            o,
            o.status == OrderStatus.Paid ? ToKleanCatalog.Outcome.Restock : ToKleanCatalog.Outcome.Release
        );
    }

    // ================================================================== disputas

    /// @notice El comprador disputa un pedido enviado antes de la liberación automática.
    function openDispute(uint256 orderId, string calldata reasonURI) external {
        Order storage o = _order(orderId);
        if (o.buyer != msg.sender) revert NotOrderBuyer(orderId);
        if (o.status != OrderStatus.Shipped) revert InvalidOrderStatus(orderId, o.status);
        if (block.timestamp >= o.deadline) revert TooLate(orderId, o.deadline);
        _checkUri(reasonURI);
        o.status = OrderStatus.Disputed;
        o.deadline = uint64(block.timestamp) + resolutionWindow;
        emit DisputeOpened(orderId, reasonURI);
    }

    /// @notice El árbitro reparte el pago: `buyerBps` (0-10000) vuelve al comprador y el resto al vendedor (con
    ///         comisión). En productos vinculados, `nftToBuyer` decide si el pasaporte viaja al comprador.
    function resolveDispute(uint256 orderId, uint16 buyerBps, bool nftToBuyer, string calldata rulingURI)
        external
        onlyRole(ARBITER_ROLE)
    {
        Order storage o = _order(orderId);
        if (o.status != OrderStatus.Disputed) revert InvalidOrderStatus(orderId, o.status);
        if (buyerBps > BPS) revert InvalidBps(buyerBps);
        _checkUri(rulingURI);

        uint256 buyerShare = uint256(o.amount) * buyerBps / BPS;
        uint256 sellerGross = o.amount - buyerShare;
        uint256 fee = sellerGross * o.feeBps / BPS;

        o.status = OrderStatus.Resolved;
        _credit(o.buyer, o.paymentId, buyerShare);
        _credit(o.seller, o.paymentId, sellerGross - fee);
        _credit(treasury, o.paymentId, fee);
        catalog.finish(
            o.listingId,
            o.qty,
            o.buyer,
            nftToBuyer ? ToKleanCatalog.Outcome.Deliver : ToKleanCatalog.Outcome.Return
        );
        emit DisputeResolved(orderId, buyerBps, nftToBuyer, rulingURI);
    }

    /// @notice Si el árbitro no resuelve a tiempo, el comprador recupera todo el pago.
    function claimDisputeTimeout(uint256 orderId) external {
        Order storage o = _order(orderId);
        if (o.buyer != msg.sender) revert NotOrderBuyer(orderId);
        if (o.status != OrderStatus.Disputed) revert InvalidOrderStatus(orderId, o.status);
        if (block.timestamp < o.deadline) revert TooEarly(orderId, o.deadline);
        _refund(orderId, o, ToKleanCatalog.Outcome.Return);
    }

    // ================================================================== valoraciones y retiros

    /// @notice Valoración 1-5 de una compra completada (una vez por pedido).
    function rate(uint256 orderId, uint8 score) external {
        Order storage o = _order(orderId);
        if (o.buyer != msg.sender) revert NotOrderBuyer(orderId);
        if (o.status != OrderStatus.Completed) revert InvalidOrderStatus(orderId, o.status);
        if (score < 1 || score > 5) revert InvalidScore(score);
        if (o.rated) revert AlreadyRated(orderId);
        o.rated = true;
        registry.recordRating(o.seller, score);
        emit Rated(orderId, o.seller, score);
    }

    /// @notice Envía a `account` lo acreditado en el token `id`. Lo puede ejecutar cualquiera (relayer/backend);
    ///         los fondos siempre van a `account`.
    function withdraw(address account, uint256 id) external nonReentrant {
        uint256 amount = claimable[account][id];
        if (amount == 0) revert NothingToWithdraw();
        claimable[account][id] = 0;
        emit Withdrawn(account, id, amount);
        token.safeTransferFrom(address(this), account, id, amount, "");
    }

    // ================================================================== parámetros

    /// @notice Comisión por venta (máx. 10 %) y POR emitido al comprar un producto limpio (máx. 50 % del pago).
    ///         No afecta a pedidos ya creados.
    function setRates(uint16 feeBps_, uint16 porRewardBps_) external onlyRole(PARAMETERS_ROLE) {
        _setRates(feeBps_, porRewardBps_);
    }

    function setTreasury(address treasury_) external onlyRole(PARAMETERS_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Ventanas en segundos: envío 1-30 días, confirmación 3-60 días, resolución 7-90 días.
    function setWindows(uint32 ship, uint32 confirm, uint32 resolution) external onlyRole(PARAMETERS_ROLE) {
        if (
            ship < 1 days || ship > 30 days || confirm < 3 days || confirm > 60 days || resolution < 7 days
                || resolution > 90 days
        ) revert InvalidWindow();
        shipWindow = ship;
        confirmWindow = confirm;
        resolutionWindow = resolution;
        emit WindowsUpdated(ship, confirm, resolution);
    }

    // ================================================================== vistas

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _order(orderId);
    }

    // ================================================================== internos

    function _complete(uint256 orderId, Order storage o) private {
        o.status = OrderStatus.Completed;
        uint256 fee = uint256(o.amount) * o.feeBps / BPS;
        uint256 sellerAmount = o.amount - fee;
        _credit(o.seller, o.paymentId, sellerAmount);
        _credit(treasury, o.paymentId, fee);
        registry.recordSale(o.seller);
        catalog.finish(o.listingId, o.qty, o.buyer, ToKleanCatalog.Outcome.Deliver);

        if (o.porBps != 0) {
            uint256 reward = uint256(o.amount) * o.porBps / BPS;
            // Un fallo al emitir POR (sin rol, token en pausa) no puede bloquear el cobro del vendedor.
            try token.mint(o.buyer, POR_ID, reward) {
                emit PorRewarded(orderId, o.buyer, reward, true);
            } catch {
                emit PorRewarded(orderId, o.buyer, reward, false);
            }
        }
        emit OrderCompleted(orderId, sellerAmount, fee);
    }

    function _refund(uint256 orderId, Order storage o, ToKleanCatalog.Outcome outcome) private {
        o.status = OrderStatus.Refunded;
        _credit(o.buyer, o.paymentId, o.amount);
        catalog.finish(o.listingId, o.qty, o.buyer, outcome);
        emit OrderRefunded(orderId, o.amount);
    }

    function _setRates(uint16 feeBps_, uint16 porRewardBps_) private {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        if (porRewardBps_ > MAX_POR_BPS) revert RewardTooHigh(porRewardBps_);
        feeBps = feeBps_;
        porRewardBps = porRewardBps_;
        emit RatesUpdated(feeBps_, porRewardBps_);
    }

    function _credit(address account, uint256 id, uint256 amount) private {
        if (amount == 0) return;
        claimable[account][id] += amount;
    }

    function _order(uint256 orderId) private view returns (Order storage) {
        if (orderId == 0 || orderId > _orders.length) revert UnknownOrder(orderId);
        return _orders[orderId - 1];
    }

    function _checkUri(string calldata uri) private pure {
        uint256 len = bytes(uri).length;
        if (len == 0 || len > MAX_URI_LENGTH) revert InvalidUri();
    }

    // ---------------------------------------------------------------- recepción de tokens

    /// @dev Sólo se acepta el pago que este mismo contrato trae vía `buy()`.
    function onERC1155Received(address operator, address, uint256 id, uint256, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(token) || operator != address(this) || id < 1 || id > 3) {
            revert DirectTransferNotAllowed();
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
        returns (bytes4)
    {
        revert DirectTransferNotAllowed();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Holder, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
