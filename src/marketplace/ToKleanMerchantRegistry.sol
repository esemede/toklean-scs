// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ToKleanMerchantRegistry
/// @notice Registro de comercios del marketplace: postulación, aprobación por compliance, suspensión y reputación.
/// @dev Contrato aparte del marketplace para mantener cada pieza bajo ~10 KB (en Sepolia hoy se pagan ~1.600 de gas
///      por byte de código, y el tope por transacción es 16,7 M). El `ToKleanMarketplace` lee `isApproved` y escribe
///      ventas y valoraciones con `MARKETPLACE_ROLE`.
///      El perfil (nombre, país, contacto, certificados) vive off-chain: aquí sólo se guarda su hash y la URI se emite
///      en eventos para que el backend la indexe.
contract ToKleanMerchantRegistry is AccessControl {
    /// @notice Aprueba, rechaza y suspende comercios (comité de compliance).
    bytes32 public constant MERCHANT_ADMIN_ROLE = keccak256("MERCHANT_ADMIN_ROLE");
    /// @notice Marketplaces autorizados a registrar ventas y valoraciones.
    bytes32 public constant MARKETPLACE_ROLE = keccak256("MARKETPLACE_ROLE");

    uint256 public constant MAX_URI_LENGTH = 256;

    enum Status {
        None,
        Pending,
        Approved,
        Rejected,
        Suspended
    }

    struct Merchant {
        Status status;
        uint32 completedSales;
        uint32 ratingCount;
        uint64 ratingSum;
        uint64 since;
        bytes32 profileHash;
    }

    mapping(address account => Merchant) private _merchants;

    event MerchantApplied(address indexed merchant, string profileURI);
    event MerchantReviewed(address indexed merchant, bool approved, address indexed reviewer);
    event MerchantSuspended(address indexed merchant, bool suspended, address indexed by);
    event SaleRecorded(address indexed merchant, uint32 completedSales);
    event Rated(address indexed merchant, uint8 score);

    error ZeroAddress();
    error InvalidUri();
    error InvalidScore(uint8 score);
    error NotMerchant(address account);
    error NotPending(address account);
    error AlreadyRegistered(address account);
    error NotSuspended(address account);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MERCHANT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ comercio

    /// @notice Postula a la cuenta como comercio. Puede volver a postular si fue rechazada.
    function applyAsMerchant(string calldata profileURI) external {
        Merchant storage m = _merchants[msg.sender];
        if (m.status != Status.None && m.status != Status.Rejected) revert AlreadyRegistered(msg.sender);
        m.status = Status.Pending;
        m.since = uint64(block.timestamp);
        _setProfile(m, profileURI);
    }

    /// @notice Un comercio pendiente o aprobado actualiza su perfil.
    function updateProfile(string calldata profileURI) external {
        Merchant storage m = _merchants[msg.sender];
        if (m.status != Status.Pending && m.status != Status.Approved) revert NotMerchant(msg.sender);
        _setProfile(m, profileURI);
    }

    // ------------------------------------------------------------------ compliance

    function reviewMerchant(address account, bool approved) external onlyRole(MERCHANT_ADMIN_ROLE) {
        Merchant storage m = _merchants[account];
        if (m.status != Status.Pending) revert NotPending(account);
        m.status = approved ? Status.Approved : Status.Rejected;
        emit MerchantReviewed(account, approved, msg.sender);
    }

    /// @notice Suspende o reintegra a un comercio. Sus pedidos abiertos siguen su curso.
    function setSuspended(address account, bool suspended) external onlyRole(MERCHANT_ADMIN_ROLE) {
        Merchant storage m = _merchants[account];
        if (suspended) {
            if (m.status != Status.Approved) revert NotMerchant(account);
            m.status = Status.Suspended;
        } else {
            if (m.status != Status.Suspended) revert NotSuspended(account);
            m.status = Status.Approved;
        }
        emit MerchantSuspended(account, suspended, msg.sender);
    }

    // ------------------------------------------------------------------ marketplace

    function recordSale(address account) external onlyRole(MARKETPLACE_ROLE) {
        emit SaleRecorded(account, ++_merchants[account].completedSales);
    }

    function recordRating(address account, uint8 score) external onlyRole(MARKETPLACE_ROLE) {
        if (score < 1 || score > 5) revert InvalidScore(score);
        Merchant storage m = _merchants[account];
        m.ratingSum += score;
        m.ratingCount += 1;
        emit Rated(account, score);
    }

    // ------------------------------------------------------------------ vistas

    function isApproved(address account) external view returns (bool) {
        return _merchants[account].status == Status.Approved;
    }

    function getMerchant(address account) external view returns (Merchant memory) {
        return _merchants[account];
    }

    /// @notice Promedio de valoraciones multiplicado por 100 (450 = 4,5 estrellas); 0 sin valoraciones.
    function ratingOf(address account) external view returns (uint256 average100, uint256 count) {
        Merchant storage m = _merchants[account];
        count = m.ratingCount;
        average100 = count == 0 ? 0 : uint256(m.ratingSum) * 100 / count;
    }

    function _setProfile(Merchant storage m, string calldata profileURI) private {
        uint256 len = bytes(profileURI).length;
        if (len == 0 || len > MAX_URI_LENGTH) revert InvalidUri();
        m.profileHash = keccak256(bytes(profileURI));
        emit MerchantApplied(msg.sender, profileURI);
    }
}
