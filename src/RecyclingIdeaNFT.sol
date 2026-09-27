// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ImpactNFTBase} from "./common/ImpactNFTBase.sol";

/// @title RecyclingIdeaNFT
/// @notice NFT de una idea de reciclaje/reutilización: prueba de autoría con sello de tiempo,
///         respaldo comunitario, curaduría y registro de implementaciones reales.
/// @dev - El contenido completo (documento, planos, video) vive off-chain; on-chain queda su hash, que es único:
///        nadie puede volver a registrar la misma idea (prueba de anterioridad).
///      - El autor queda fijo aunque el NFT se transfiera y recibe regalías ERC-2981 en reventas.
///      - Los productos circulares (`CircularProductNFT`) pueden referenciar la idea que los inspiró.
contract RecyclingIdeaNFT is ImpactNFTBase, ERC2981 {
    using Strings for uint256;

    enum IdeaStatus {
        Proposed,
        UnderReview,
        Approved,
        Implemented,
        Rejected
    }

    struct Idea {
        address author;
        uint64 createdAt;
        IdeaStatus status;
        uint32 endorsements;
        uint32 implementations;
        bytes32 contentHash;
        string title;
        string category;
        string contentURI;
    }

    struct Implementation {
        address implementer;
        address verifier;
        uint64 timestamp;
        bytes32 evidenceHash;
        string evidenceURI;
    }

    uint96 public constant AUTHOR_ROYALTY_BPS = 500; // 5 %
    uint256 public constant MAX_TITLE_LENGTH = 120;

    mapping(uint256 => Idea) private _ideas;
    mapping(uint256 => Implementation[]) private _implementations;
    mapping(bytes32 => uint256) public ideaIdByContentHash;
    mapping(uint256 => mapping(address => bool)) public hasEndorsed;
    mapping(address => uint256) public ideasBy;

    event IdeaProposed(
        uint256 indexed tokenId, address indexed author, bytes32 indexed contentHash, string title
    );
    event IdeaEndorsed(uint256 indexed tokenId, address indexed endorser, uint32 total);
    event IdeaReviewed(uint256 indexed tokenId, address indexed curator, IdeaStatus status, bytes32 noteHash);
    event ImplementationRegistered(
        uint256 indexed tokenId,
        uint256 index,
        address indexed implementer,
        address indexed verifier,
        bytes32 evidenceHash
    );

    error IdeaAlreadyRegistered(uint256 existingId);
    error TitleTooLong();
    error InvalidStatus(uint256 tokenId, IdeaStatus current);
    error InvalidTransition(IdeaStatus from, IdeaStatus to);
    error AlreadyEndorsed(uint256 tokenId, address endorser);
    error AuthorCannotEndorse(uint256 tokenId);

    constructor(address admin, string memory imageBaseURI_)
        ImpactNFTBase("ToKlean Recycling Idea", "TKIDEA", admin, imageBaseURI_)
    {}

    // ------------------------------------------------------------ actions

    function proposeIdea(
        string calldata title,
        string calldata category,
        bytes32 contentHash,
        string calldata contentURI
    ) external whenNotPaused returns (uint256 tokenId) {
        _requireNonEmpty(title);
        if (bytes(title).length > MAX_TITLE_LENGTH) revert TitleTooLong();
        _requireEvidence(contentHash);
        uint256 existing = ideaIdByContentHash[contentHash];
        if (existing != 0) revert IdeaAlreadyRegistered(existing);

        tokenId = _mintNext(msg.sender);
        Idea storage i = _ideas[tokenId];
        i.author = msg.sender;
        i.createdAt = uint64(block.timestamp);
        i.contentHash = contentHash;
        i.title = title;
        i.category = category;
        i.contentURI = contentURI;

        ideaIdByContentHash[contentHash] = tokenId;
        unchecked {
            ideasBy[msg.sender]++;
        }
        _setTokenRoyalty(tokenId, msg.sender, AUTHOR_ROYALTY_BPS);
        emit IdeaProposed(tokenId, msg.sender, contentHash, title);
    }

    /// @notice Respaldo comunitario: una vez por cuenta. Es una señal, no una votación vinculante
    ///         (la resistencia sybil se delega a la curaduría o a un gate por token/identidad en el front).
    function endorse(uint256 tokenId) external whenNotPaused {
        Idea storage i = _idea(tokenId);
        if (msg.sender == i.author) revert AuthorCannotEndorse(tokenId);
        if (i.status == IdeaStatus.Rejected) revert InvalidStatus(tokenId, i.status);
        if (hasEndorsed[tokenId][msg.sender]) revert AlreadyEndorsed(tokenId, msg.sender);
        hasEndorsed[tokenId][msg.sender] = true;
        unchecked {
            i.endorsements++;
        }
        emit IdeaEndorsed(tokenId, msg.sender, i.endorsements);
    }

    function review(uint256 tokenId, IdeaStatus newStatus, bytes32 noteHash)
        external
        onlyRole(VERIFIER_ROLE)
        whenNotPaused
    {
        Idea storage i = _idea(tokenId);
        if (msg.sender == i.author) revert SelfVerification(tokenId, msg.sender);
        IdeaStatus current = i.status;
        if (current != IdeaStatus.Proposed && current != IdeaStatus.UnderReview) {
            revert InvalidStatus(tokenId, current);
        }
        if (
            newStatus != IdeaStatus.UnderReview && newStatus != IdeaStatus.Approved
                && newStatus != IdeaStatus.Rejected
        ) {
            revert InvalidTransition(current, newStatus);
        }
        i.status = newStatus;
        emit IdeaReviewed(tokenId, msg.sender, newStatus, noteHash);
    }

    function registerImplementation(
        uint256 tokenId,
        address implementer,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external onlyRole(VERIFIER_ROLE) whenNotPaused {
        Idea storage i = _idea(tokenId);
        if (i.status != IdeaStatus.Approved && i.status != IdeaStatus.Implemented) {
            revert InvalidStatus(tokenId, i.status);
        }
        if (implementer == address(0)) revert ZeroAddress();
        if (msg.sender == implementer) revert SelfVerification(tokenId, msg.sender);
        _requireEvidence(evidenceHash);

        i.status = IdeaStatus.Implemented;
        unchecked {
            i.implementations++;
        }
        _implementations[tokenId].push(
            Implementation({
                implementer: implementer,
                verifier: msg.sender,
                timestamp: uint64(block.timestamp),
                evidenceHash: evidenceHash,
                evidenceURI: evidenceURI
            })
        );
        emit ImplementationRegistered(
            tokenId, _implementations[tokenId].length - 1, implementer, msg.sender, evidenceHash
        );
    }

    // -------------------------------------------------------------- views

    function getIdea(uint256 tokenId) external view returns (Idea memory) {
        return _idea(tokenId);
    }

    function getImplementations(uint256 tokenId) external view returns (Implementation[] memory) {
        _requireOwned(tokenId);
        return _implementations[tokenId];
    }

    function statusName(IdeaStatus s) public pure returns (string memory) {
        string[5] memory names = ["Propuesta", "En revision", "Aprobada", "Implementada", "Rechazada"];
        return names[uint256(s)];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ImpactNFTBase, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------ metadata

    function _tokenName(uint256 tokenId) internal view override returns (string memory) {
        return string.concat("Idea ToKlean #", tokenId.toString(), " - ", _ideas[tokenId].title);
    }

    function _tokenDescription(uint256) internal pure override returns (string memory) {
        return
            "Idea de reciclaje registrada en ToKlean con prueba de autoria y trazabilidad de implementaciones.";
    }

    function _imageKey(uint256 tokenId) internal view override returns (string memory) {
        string[5] memory keys = ["proposed", "review", "approved", "implemented", "rejected"];
        return string.concat("idea-", keys[uint256(_ideas[tokenId].status)], ".svg");
    }

    function _attributes(uint256 tokenId) internal view override returns (string memory) {
        Idea storage i = _ideas[tokenId];
        return string.concat(
            _attr("Categoria", i.category),
            ",",
            _attr("Estado", statusName(i.status)),
            ",",
            _attr("Autor", Strings.toHexString(i.author)),
            ",",
            _attrNum("Respaldos", i.endorsements),
            ",",
            _attrNum("Implementaciones", i.implementations),
            ",",
            _attrDate("Registrada", i.createdAt)
        );
    }

    function _idea(uint256 tokenId) internal view returns (Idea storage) {
        _requireOwned(tokenId);
        return _ideas[tokenId];
    }
}
