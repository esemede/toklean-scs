// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IProductPassport {
    function ownerOf(uint256 tokenId) external view returns (address);
    function manufacturerOf(uint256 tokenId) external view returns (address);
}

/// @title LivingProduct
/// @notice Gemelo digital "vivo" de un producto físico vendido en ToKlean. El fabricante registra la unidad con la
///         dirección de una llave que va impresa en un QR dentro del paquete. Cuando la venta termina, el pasaporte
///         (`CircularProductNFT`) queda en custodia de este contrato y quien escanea el QR reclama el NFT vivo:
///         90 % de las participaciones para el comprador y 10 % para el fabricante.
/// @dev - Las participaciones son ERC-1155 (id = id del pasaporte, 100 unidades = 100 %).
///      - Las del fabricante son intransferibles: sigue siendo parte del producto (trazabilidad y recuperación REP)
///        aunque el comprador lo venda o lo deseche. Esto es un registro de trazabilidad: no reemplaza ni traspasa las
///        obligaciones legales de la Ley REP 20.920, que siguen en el productor.
///      - El reclamo se firma con la llave del QR y la firma incluye la cuenta que reclama: quien vea la transacción
///        en la mempool no puede reutilizarla para quedarse con el NFT.
///      - Cualquier titular puede agregar eventos de trazabilidad (reparación, reventa, desecho, recuperación...).
contract LivingProduct is ERC1155 {
    uint256 public constant TOTAL_SHARES = 100;
    uint256 public constant PRODUCER_SHARES = 10;

    enum TraceKind {
        Note,
        Resale,
        Repair,
        Disposal,
        Recovery // el productor recuperó el producto o sus materiales (cierra el ciclo REP)
    }

    struct Unit {
        address producer;
        address claimKey;
        bool claimed;
        bool recovered;
        uint32 traceCount;
    }

    IProductPassport public immutable passports;
    mapping(uint256 => Unit) private _units;
    mapping(uint256 => string) private _uris;

    event UnitRegistered(uint256 indexed passportId, address indexed producer, address claimKey, string uri);
    event Claimed(uint256 indexed passportId, address indexed owner, address indexed producer);
    event TraceAdded(
        uint256 indexed passportId,
        address indexed by,
        TraceKind kind,
        bytes32 evidenceHash,
        string evidenceURI,
        bool byProducer
    );
    event UriUpdated(uint256 indexed passportId, string uri);

    error ZeroAddress();
    error NotProducer(uint256 passportId, address caller);
    error AlreadyRegistered(uint256 passportId);
    error NotRegistered(uint256 passportId);
    error AlreadyClaimed(uint256 passportId);
    error NotSoldYet(uint256 passportId);
    error BadClaimSignature();
    error NotHolder(uint256 passportId, address caller);
    error ProducerSharesLocked(uint256 passportId);
    error EmptyUri();

    constructor(IProductPassport passports_) ERC1155("") {
        if (address(passports_) == address(0)) revert ZeroAddress();
        passports = passports_;
    }

    // ------------------------------------------------------------ productor

    /// @notice El fabricante registra la unidad con la dirección de la llave del QR y la URI de su metadata y medios.
    function register(uint256 passportId, address claimKey, string calldata uri_) external {
        if (passports.manufacturerOf(passportId) != msg.sender) revert NotProducer(passportId, msg.sender);
        if (claimKey == address(0)) revert ZeroAddress();
        if (bytes(uri_).length == 0) revert EmptyUri();
        Unit storage u = _units[passportId];
        if (u.producer != address(0)) revert AlreadyRegistered(passportId);
        u.producer = msg.sender;
        u.claimKey = claimKey;
        _uris[passportId] = uri_;
        emit UnitRegistered(passportId, msg.sender, claimKey, uri_);
    }

    /// @notice El fabricante actualiza la metadata y medios del gemelo digital.
    function setUri(uint256 passportId, string calldata uri_) external {
        if (_units[passportId].producer != msg.sender) revert NotProducer(passportId, msg.sender);
        if (bytes(uri_).length == 0) revert EmptyUri();
        _uris[passportId] = uri_;
        emit UriUpdated(passportId, uri_);
    }

    // ------------------------------------------------------------ comprador

    /// @notice Reclama el NFT vivo con la firma de la llave del QR sobre (red, contrato, pasaporte, quien reclama).
    ///         Sólo cuando el producto ya fue entregado (el pasaporte está en custodia de este contrato).
    function claim(uint256 passportId, bytes calldata signature) external {
        Unit storage u = _units[passportId];
        if (u.producer == address(0)) revert NotRegistered(passportId);
        if (u.claimed) revert AlreadyClaimed(passportId);
        if (passports.ownerOf(passportId) != address(this)) revert NotSoldYet(passportId);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(claimDigest(passportId, msg.sender));
        if (ECDSA.recover(digest, signature) != u.claimKey) revert BadClaimSignature();

        u.claimed = true;
        _mint(msg.sender, passportId, TOTAL_SHARES - PRODUCER_SHARES, "");
        _mint(u.producer, passportId, PRODUCER_SHARES, "");
        emit Claimed(passportId, msg.sender, u.producer);
    }

    // ------------------------------------------------------------ trazabilidad

    /// @notice Un titular (comprador o productor) agrega un hecho de la vida del producto. El productor puede
    ///         registrar `Recovery` para marcar que recuperó el producto o sus materiales.
    function addTrace(uint256 passportId, TraceKind kind, bytes32 evidenceHash, string calldata evidenceURI)
        external
    {
        if (balanceOf(msg.sender, passportId) == 0) revert NotHolder(passportId, msg.sender);
        Unit storage u = _units[passportId];
        bool byProducer = msg.sender == u.producer;
        if (kind == TraceKind.Recovery && byProducer) u.recovered = true;
        u.traceCount += 1;
        emit TraceAdded(passportId, msg.sender, kind, evidenceHash, evidenceURI, byProducer);
    }

    // ------------------------------------------------------------ vistas

    function claimDigest(uint256 passportId, address claimer) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), passportId, claimer));
    }

    function getUnit(uint256 passportId) external view returns (Unit memory) {
        return _units[passportId];
    }

    function uri(uint256 passportId) public view override returns (string memory) {
        return _uris[passportId];
    }

    // ------------------------------------------------------------ internos

    /// @dev Las participaciones del productor no se pueden mover (sí puede recibir más).
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        if (from != address(0)) {
            for (uint256 i; i < ids.length; ++i) {
                if (from == _units[ids[i]].producer) revert ProducerSharesLocked(ids[i]);
            }
        }
        super._update(from, to, ids, values);
    }
}
