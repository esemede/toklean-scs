// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CircularProductNFT} from "../CircularProductNFT.sol";
import {ToKleanMerchantRegistry} from "./ToKleanMerchantRegistry.sol";

/// @title ToKleanCatalog
/// @notice Publicaciones del marketplace: productos y servicios de comercios aprobados, con stock, precio y medio de
///         pago, y custodia de los pasaportes `CircularProductNFT` de los productos limpios en venta.
/// @dev Es la mitad "catálogo" del marketplace; `ToKleanMarketplace` (pedidos, escrow y disputas) la usa para reservar
///      stock al comprar y para cerrar la parte NFT de cada pedido. Dividido en contratos de menos de ~10 KB porque en
///      Sepolia hoy se pagan ~1.600 de gas por byte de código y el tope por transacción es 16,7 M.
///
///      - **Producto limpio**: una publicación puede vincular un NFT *certificado* del vendedor. El NFT queda en
///        custodia aquí y viaja al comprador al completarse la venta (el pasaporte sigue al producto físico). Si la
///        certificación se revoca antes de la compra, la publicación deja de estar disponible.
///      - La URI de metadata no se guarda: se guarda su `keccak256` y la URI completa se emite en eventos (el backend
///        indexa el catálogo y lo sirve con búsqueda y filtros).
///      - La pausa bloquea publicar y comprar (el marketplace reserva stock aquí); cerrar/retirar siguen funcionando.
contract ToKleanCatalog is ERC721Holder, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Habilita medios de pago (ids del token ERC-1155: 1 TKN, 2 REC, 3 POR).
    bytes32 public constant PARAMETERS_ROLE = keccak256("PARAMETERS_ROLE");

    uint256 public constant MAX_URI_LENGTH = 256;

    /// @notice Contrato de productos limpios (address(0) = sin vínculo con productos).
    CircularProductNFT public immutable products;
    ToKleanMerchantRegistry public immutable registry;
    /// @notice Marketplace autorizado a reservar stock y cerrar pedidos. Se fija una sola vez.
    address public marketplace;
    mapping(uint256 id => bool) public acceptedPayment;
    mapping(uint256 tokenId => uint256 listingId) public listingOfProduct;

    enum Kind {
        Product,
        Service
    }

    enum Status {
        Active,
        Paused,
        Closed
    }

    /// @dev Cómo termina la parte de stock/NFT de un pedido.
    enum Outcome {
        Restock, // reembolso antes del envío: el stock vuelve
        Release, // reembolso con el pedido ya enviado: el stock no vuelve
        Return, // disputa sin entrega del NFT: el producto sigue en custodia y vuelve a estar disponible
        Deliver // venta completada: el NFT viaja al comprador
    }

    struct Listing {
        address seller;
        Kind kind;
        Status status;
        uint8 paymentId;
        bool hasProduct;
        bool nftEscrowed;
        uint32 stock;
        uint32 openOrders;
        uint64 createdAt;
        uint128 price; // por unidad, en wei del token de pago
        uint256 productTokenId;
        bytes32 metadataHash; // keccak256 de la URI de metadata
    }

    Listing[] private _listings; // id = índice + 1

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        Kind kind,
        uint256 paymentId,
        uint256 price,
        uint256 stock,
        bool hasProduct,
        uint256 productTokenId,
        string metadataURI
    );
    event ListingUpdated(uint256 indexed listingId, uint256 price, uint256 stock, string metadataURI);
    event ListingStatusChanged(uint256 indexed listingId, Status status);
    event MarketplaceSet(address marketplace);
    event PaymentTokenUpdated(uint256 indexed id, bool accepted);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidUri();
    error InvalidPaymentToken(uint256 id);
    error PaymentNotAccepted(uint256 id);
    error NotMerchant(address account);
    error NotMarketplace();
    error MarketplaceAlreadySet();
    error UnknownListing(uint256 listingId);
    error NotSeller(uint256 listingId);
    error ListingClosed(uint256 listingId);
    error ListingNotAvailable(uint256 listingId);
    error SelfPurchase();
    error InsufficientStock(uint256 requested, uint256 available);
    error PriceTooHigh(uint256 price, uint256 maxPrice);
    error ProductsNotConfigured();
    error ProductNotOwned(uint256 tokenId);
    error ProductNotCertified(uint256 tokenId);
    error ProductStockMustBeOne();
    error ProductMustBeKindProduct();
    error HasOpenOrders(uint256 listingId);
    error DirectTransferNotAllowed();

    constructor(CircularProductNFT products_, ToKleanMerchantRegistry registry_, address admin) {
        if (address(registry_) == address(0) || admin == address(0)) revert ZeroAddress();
        products = products_;
        registry = registry_;
        acceptedPayment[1] = true; // TKN
        acceptedPayment[2] = true; // REC
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(PARAMETERS_ROLE, admin);
        emit PaymentTokenUpdated(1, true);
        emit PaymentTokenUpdated(2, true);
    }

    // ================================================================== vendedor

    /// @notice Publica un producto o servicio. Si `hasProduct`, el NFT `productTokenId` (certificado, propio y con
    ///         `approve`/`setApprovalForAll` a este contrato) queda en custodia hasta que se venda o se cierre.
    function createListing(
        Kind kind,
        uint256 paymentId,
        uint128 price,
        uint32 stock,
        string calldata metadataURI,
        bool hasProduct,
        uint256 productTokenId
    ) external whenNotPaused nonReentrant returns (uint256 listingId) {
        if (!registry.isApproved(msg.sender)) revert NotMerchant(msg.sender);
        if (price == 0 || stock == 0) revert ZeroAmount();
        if (!acceptedPayment[paymentId]) revert PaymentNotAccepted(paymentId);
        bytes32 uriHash = _uriHash(metadataURI);

        if (hasProduct) {
            if (address(products) == address(0)) revert ProductsNotConfigured();
            if (kind != Kind.Product) revert ProductMustBeKindProduct();
            if (stock != 1) revert ProductStockMustBeOne();
            if (products.ownerOf(productTokenId) != msg.sender) revert ProductNotOwned(productTokenId);
            if (!_isCertified(productTokenId)) revert ProductNotCertified(productTokenId);
        }

        _listings.push(
            Listing({
                seller: msg.sender,
                kind: kind,
                status: Status.Active,
                paymentId: uint8(paymentId),
                hasProduct: hasProduct,
                nftEscrowed: hasProduct,
                stock: stock,
                openOrders: 0,
                createdAt: uint64(block.timestamp),
                price: price,
                productTokenId: hasProduct ? productTokenId : 0,
                metadataHash: uriHash
            })
        );
        listingId = _listings.length;

        if (hasProduct) {
            listingOfProduct[productTokenId] = listingId;
            products.safeTransferFrom(msg.sender, address(this), productTokenId);
        }
        emit ListingCreated(
            listingId, msg.sender, kind, paymentId, price, stock, hasProduct, productTokenId, metadataURI
        );
    }

    /// @notice Cambia precio, stock y metadata. Los productos vinculados mantienen stock 1.
    function updateListing(uint256 listingId, uint128 price, uint32 stock, string calldata metadataURI)
        external
    {
        Listing storage l = _openListing(listingId);
        if (price == 0) revert ZeroAmount();
        if (l.hasProduct && stock != l.stock) revert ProductStockMustBeOne();
        l.metadataHash = _uriHash(metadataURI);
        l.price = price;
        l.stock = stock;
        emit ListingUpdated(listingId, price, stock, metadataURI);
    }

    function setListingPaused(uint256 listingId, bool paused_) external {
        Listing storage l = _openListing(listingId);
        l.status = paused_ ? Status.Paused : Status.Active;
        emit ListingStatusChanged(listingId, l.status);
    }

    /// @notice Cierra la publicación para siempre y devuelve el NFT en custodia. Un producto vinculado no se puede
    ///         cerrar con pedidos abiertos.
    function closeListing(uint256 listingId) external nonReentrant {
        Listing storage l = _openListing(listingId);
        if (l.hasProduct && l.openOrders != 0) revert HasOpenOrders(listingId);
        l.status = Status.Closed;
        l.stock = 0;
        if (l.nftEscrowed) {
            l.nftEscrowed = false;
            delete listingOfProduct[l.productTokenId];
            products.transferFrom(address(this), l.seller, l.productTokenId);
        }
        emit ListingStatusChanged(listingId, Status.Closed);
    }

    // ================================================================== marketplace

    /// @notice Reserva `qty` unidades para un pedido. Sólo el marketplace.
    function reserve(uint256 listingId, uint32 qty, uint256 maxUnitPrice, address buyer)
        external
        whenNotPaused
        returns (address seller, uint128 price, uint8 paymentId, bool hasProduct)
    {
        if (msg.sender != marketplace) revert NotMarketplace();
        Listing storage l = _listing(listingId);
        if (l.status != Status.Active || !registry.isApproved(l.seller)) {
            revert ListingNotAvailable(listingId);
        }
        if (l.seller == buyer) revert SelfPurchase();
        if (qty > l.stock) revert InsufficientStock(qty, l.stock);
        if (l.price > maxUnitPrice) revert PriceTooHigh(l.price, maxUnitPrice);
        if (l.hasProduct && !_isCertified(l.productTokenId)) revert ProductNotCertified(l.productTokenId);
        l.stock -= qty;
        l.openOrders += 1;
        return (l.seller, l.price, l.paymentId, l.hasProduct);
    }

    /// @notice Cierra la parte de stock/NFT de un pedido terminado. Sólo el marketplace.
    function finish(uint256 listingId, uint32 qty, address buyer, Outcome outcome) external {
        if (msg.sender != marketplace) revert NotMarketplace();
        Listing storage l = _listings[listingId - 1];
        l.openOrders -= 1;
        if (outcome == Outcome.Restock) {
            if (l.status != Status.Closed) l.stock += qty;
        } else if (!l.hasProduct || !l.nftEscrowed) {
            return;
        } else if (outcome == Outcome.Deliver) {
            l.nftEscrowed = false;
            l.status = Status.Closed;
            l.stock = 0;
            delete listingOfProduct[l.productTokenId];
            emit ListingStatusChanged(listingId, Status.Closed);
            products.transferFrom(address(this), buyer, l.productTokenId);
        } else if (outcome == Outcome.Return && l.status != Status.Closed) {
            l.stock = 1;
        }
    }

    // ================================================================== administración

    /// @notice Fija el marketplace autorizado. Sólo una vez (el contrato es inmutable en lo que protege).
    function setMarketplace(address marketplace_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (marketplace_ == address(0)) revert ZeroAddress();
        if (marketplace != address(0)) revert MarketplaceAlreadySet();
        marketplace = marketplace_;
        emit MarketplaceSet(marketplace_);
    }

    /// @notice Habilita o deshabilita un id del token (1 TKN, 2 REC, 3 POR) como medio de pago de nuevas publicaciones.
    function setAcceptedPayment(uint256 id, bool accepted) external onlyRole(PARAMETERS_ROLE) {
        if (id < 1 || id > 3) revert InvalidPaymentToken(id);
        acceptedPayment[id] = accepted;
        emit PaymentTokenUpdated(id, accepted);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ================================================================== vistas

    function listingCount() external view returns (uint256) {
        return _listings.length;
    }

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listing(listingId);
    }

    /// @notice El producto vinculado está certificado ahora mismo (y su NFT sigue en custodia).
    function isCleanVerified(uint256 listingId) public view returns (bool) {
        Listing storage l = _listing(listingId);
        if (!l.hasProduct || !l.nftEscrowed) return false;
        (bool ok, bool certified) = _productCertified(l.productTokenId);
        return ok && certified;
    }

    /// @notice Se puede comprar ahora mismo (activa, con stock, comercio aprobado y producto aún certificado).
    function isAvailable(uint256 listingId) external view returns (bool) {
        Listing storage l = _listing(listingId);
        return l.status == Status.Active && l.stock > 0 && registry.isApproved(l.seller)
            && (!l.hasProduct || isCleanVerified(listingId));
    }

    // ================================================================== internos

    /// @dev `CircularProductNFT.getProduct` devuelve un struct con un string; en vez de decodificarlo entero (código
    ///      caro de desplegar) se lee sólo la palabra `status`, el 5º campo del struct (offset 0x20 + 4 * 0x20).
    function _productCertified(uint256 tokenId) private view returns (bool ok, bool certified) {
        address target = address(products);
        bytes4 selector = CircularProductNFT.getProduct.selector;
        uint256 status;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), tokenId)
            ok := staticcall(gas(), target, ptr, 0x24, ptr, 0xc0)
            if lt(returndatasize(), 0xc0) { ok := 0 }
            status := mload(add(ptr, 0xa0))
        }
        certified = ok && status == uint256(CircularProductNFT.CleanStatus.Certified);
    }

    /// @dev Revierte si el NFT no existe o no está certificado.
    function _isCertified(uint256 tokenId) private view returns (bool) {
        (bool ok, bool certified) = _productCertified(tokenId);
        if (!ok) revert ProductNotCertified(tokenId);
        return certified;
    }

    function _listing(uint256 listingId) private view returns (Listing storage) {
        if (listingId == 0 || listingId > _listings.length) revert UnknownListing(listingId);
        return _listings[listingId - 1];
    }

    /// @dev Publicación existente, del vendedor que llama y no cerrada.
    function _openListing(uint256 listingId) private view returns (Listing storage l) {
        l = _listing(listingId);
        if (l.seller != msg.sender) revert NotSeller(listingId);
        if (l.status == Status.Closed) revert ListingClosed(listingId);
    }

    function _uriHash(string calldata uri) private pure returns (bytes32) {
        uint256 len = bytes(uri).length;
        if (len == 0 || len > MAX_URI_LENGTH) revert InvalidUri();
        return keccak256(bytes(uri));
    }

    /// @dev Sólo se acepta el NFT de producto que este contrato trae en `createListing()`.
    function onERC721Received(address operator, address, uint256, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(products) || operator != address(this)) {
            revert DirectTransferNotAllowed();
        }
        return this.onERC721Received.selector;
    }
}
