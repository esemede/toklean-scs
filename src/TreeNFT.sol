// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ImpactNFTBase} from "./common/ImpactNFTBase.sol";

/// @title TreeNFT
/// @notice NFT de un árbol plantado con trazabilidad de su crecimiento.
/// @dev Flujo:
///      1. `plant`            -> el plantador registra el árbol (foto + GPS) y recibe el NFT en estado Pending.
///      2. `verifyPlanting`   -> un VERIFIER (distinto del plantador) lo aprueba (Verified) o rechaza (Rejected)
///                               y fija la estimación de captura de CO2.
///      3. `recordCheckpoint` -> visitas periódicas de un VERIFIER: altura, salud y estado (Growing/Mature/Dead).
///      4. `reportProgress`   -> el dueño o plantador sube evidencias (fotos) entre visitas; sólo emite evento.
///      El NFT es transferible (apadrinamiento), pero el plantador original queda registrado para siempre.
contract TreeNFT is ImpactNFTBase {
    using Strings for uint256;

    enum TreeStatus {
        Pending,
        Verified,
        Growing,
        Mature,
        Dead,
        Rejected
    }

    struct Tree {
        address planter;
        uint64 plantedAt;
        uint64 verifiedAt;
        uint64 endedAt;
        int32 latE6;
        int32 lonE6;
        uint32 co2KgPerYear;
        uint32 heightCm;
        TreeStatus status;
        string species;
    }

    struct Checkpoint {
        uint64 timestamp;
        uint32 heightCm;
        uint8 healthScore;
        TreeStatus status;
        address actor;
        bytes32 evidenceHash;
        string evidenceURI;
    }

    /// @notice Tope de sanidad para la estimación de captura (un árbol adulto grande ~ 20-50 kg/año).
    uint32 public constant MAX_CO2_KG_PER_YEAR = 500;

    mapping(uint256 => Tree) private _trees;
    mapping(uint256 => Checkpoint[]) private _checkpoints;

    mapping(address => uint256) public verifiedTreesBy;
    uint256 public totalVerifiedTrees;

    event TreePlanted(
        uint256 indexed tokenId,
        address indexed planter,
        string species,
        int32 latE6,
        int32 lonE6,
        bytes32 evidenceHash
    );
    event PlantingVerified(
        uint256 indexed tokenId, address indexed verifier, bool approved, uint32 co2KgPerYear
    );
    event CheckpointRecorded(
        uint256 indexed tokenId,
        uint256 indexed index,
        TreeStatus status,
        uint32 heightCm,
        uint8 healthScore,
        address indexed verifier
    );
    event ProgressReported(
        uint256 indexed tokenId, address indexed reporter, bytes32 evidenceHash, string evidenceURI
    );

    error InvalidStatus(uint256 tokenId, TreeStatus current);
    error InvalidTransition(TreeStatus from, TreeStatus to);
    error InvalidHealthScore(uint8 score);
    error Co2EstimateTooHigh(uint32 value);
    error PlantedInFuture(uint64 plantedAt);
    error NotOwnerOrPlanter(uint256 tokenId, address caller);

    constructor(address admin, string memory imageBaseURI_)
        ImpactNFTBase("ToKlean Tree", "TKTREE", admin, imageBaseURI_)
    {}

    // ------------------------------------------------------------ actions

    function plant(
        string calldata species,
        int32 latE6,
        int32 lonE6,
        uint64 plantedAt,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external whenNotPaused returns (uint256 tokenId) {
        _requireNonEmpty(species);
        _checkCoordinates(latE6, lonE6);
        _requireEvidence(evidenceHash);
        if (plantedAt == 0) plantedAt = uint64(block.timestamp);
        if (plantedAt > block.timestamp) revert PlantedInFuture(plantedAt);

        tokenId = _mintNext(msg.sender);
        Tree storage t = _trees[tokenId];
        t.planter = msg.sender;
        t.plantedAt = plantedAt;
        t.latE6 = latE6;
        t.lonE6 = lonE6;
        t.species = species;
        // status = Pending (0)

        _pushCheckpoint(tokenId, 0, 0, TreeStatus.Pending, evidenceHash, evidenceURI);
        emit TreePlanted(tokenId, msg.sender, species, latE6, lonE6, evidenceHash);
    }

    function verifyPlanting(
        uint256 tokenId,
        bool approved,
        uint32 co2KgPerYear,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external onlyRole(VERIFIER_ROLE) whenNotPaused {
        Tree storage t = _tree(tokenId);
        if (t.status != TreeStatus.Pending) revert InvalidStatus(tokenId, t.status);
        _requireIndependent(tokenId, t);
        _requireEvidence(evidenceHash);

        if (approved) {
            if (co2KgPerYear > MAX_CO2_KG_PER_YEAR) revert Co2EstimateTooHigh(co2KgPerYear);
            t.status = TreeStatus.Verified;
            t.verifiedAt = uint64(block.timestamp);
            t.co2KgPerYear = co2KgPerYear;
            unchecked {
                verifiedTreesBy[t.planter]++;
                totalVerifiedTrees++;
            }
        } else {
            t.status = TreeStatus.Rejected;
        }
        _pushCheckpoint(tokenId, t.heightCm, approved ? 100 : 0, t.status, evidenceHash, evidenceURI);
        emit PlantingVerified(tokenId, msg.sender, approved, co2KgPerYear);
    }

    function recordCheckpoint(
        uint256 tokenId,
        uint32 heightCm,
        uint8 healthScore,
        TreeStatus newStatus,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external onlyRole(VERIFIER_ROLE) whenNotPaused {
        Tree storage t = _tree(tokenId);
        TreeStatus current = t.status;
        if (current != TreeStatus.Verified && current != TreeStatus.Growing && current != TreeStatus.Mature) {
            revert InvalidStatus(tokenId, current);
        }
        if (
            (newStatus != TreeStatus.Growing
                    && newStatus != TreeStatus.Mature
                    && newStatus != TreeStatus.Dead)
                || (current == TreeStatus.Mature && newStatus == TreeStatus.Growing)
        ) revert InvalidTransition(current, newStatus);
        if (healthScore > 100) revert InvalidHealthScore(healthScore);
        _requireIndependent(tokenId, t);
        _requireEvidence(evidenceHash);

        t.status = newStatus;
        t.heightCm = heightCm;
        if (newStatus == TreeStatus.Dead) t.endedAt = uint64(block.timestamp);

        _pushCheckpoint(tokenId, heightCm, healthScore, newStatus, evidenceHash, evidenceURI);
    }

    function reportProgress(uint256 tokenId, bytes32 evidenceHash, string calldata evidenceURI)
        external
        whenNotPaused
    {
        Tree storage t = _tree(tokenId);
        if (msg.sender != ownerOf(tokenId) && msg.sender != t.planter) {
            revert NotOwnerOrPlanter(tokenId, msg.sender);
        }
        _requireEvidence(evidenceHash);
        emit ProgressReported(tokenId, msg.sender, evidenceHash, evidenceURI);
    }

    // -------------------------------------------------------------- views

    function getTree(uint256 tokenId) external view returns (Tree memory) {
        return _tree(tokenId);
    }

    function getCheckpoints(uint256 tokenId) external view returns (Checkpoint[] memory) {
        _requireOwned(tokenId);
        return _checkpoints[tokenId];
    }

    function checkpointCount(uint256 tokenId) external view returns (uint256) {
        return _checkpoints[tokenId].length;
    }

    /// @notice CO2 capturado estimado (kg) desde la verificación hasta hoy o hasta la muerte del árbol.
    function estimatedCo2Kg(uint256 tokenId) public view returns (uint256) {
        Tree storage t = _tree(tokenId);
        if (t.verifiedAt == 0) return 0;
        uint256 end = t.endedAt != 0 ? t.endedAt : block.timestamp;
        return uint256(t.co2KgPerYear) * (end - t.verifiedAt) / 365 days;
    }

    function statusName(TreeStatus s) public pure returns (string memory) {
        string[6] memory names = ["Pendiente", "Verificado", "Creciendo", "Maduro", "Muerto", "Rechazado"];
        return names[uint256(s)];
    }

    // ------------------------------------------------------------ metadata

    function _tokenName(uint256 tokenId) internal view override returns (string memory) {
        return string.concat("Arbol ToKlean #", tokenId.toString(), " - ", _trees[tokenId].species);
    }

    function _tokenDescription(uint256) internal pure override returns (string memory) {
        return "Arbol plantado y verificado por la comunidad ToKlean. Su crecimiento se registra on-chain.";
    }

    function _imageKey(uint256 tokenId) internal view override returns (string memory) {
        string[6] memory keys = ["pending", "verified", "growing", "mature", "dead", "rejected"];
        return string.concat("tree-", keys[uint256(_trees[tokenId].status)], ".svg");
    }

    function _attributes(uint256 tokenId) internal view override returns (string memory) {
        Tree storage t = _trees[tokenId];
        string memory a = string.concat(
            _attr("Especie", t.species),
            ",",
            _attr("Estado", statusName(t.status)),
            ",",
            _attr("Latitud", _formatE6(t.latE6)),
            ",",
            _attr("Longitud", _formatE6(t.lonE6)),
            ","
        );
        return string.concat(
            a,
            _attrNum("Altura (cm)", t.heightCm),
            ",",
            _attrNum("CO2 kg/anio", t.co2KgPerYear),
            ",",
            _attrNum("CO2 estimado (kg)", estimatedCo2Kg(tokenId)),
            ",",
            _attrNum("Controles", _checkpoints[tokenId].length),
            ",",
            _attrDate("Plantado", t.plantedAt)
        );
    }

    // ------------------------------------------------------------ internal

    function _tree(uint256 tokenId) internal view returns (Tree storage) {
        _requireOwned(tokenId);
        return _trees[tokenId];
    }

    /// @dev Separación de funciones: quien planta o posee el árbol no puede auto-verificarlo.
    function _requireIndependent(uint256 tokenId, Tree storage t) internal view {
        if (msg.sender == t.planter || msg.sender == ownerOf(tokenId)) {
            revert SelfVerification(tokenId, msg.sender);
        }
    }

    function _pushCheckpoint(
        uint256 tokenId,
        uint32 heightCm,
        uint8 healthScore,
        TreeStatus status,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) internal {
        _checkpoints[tokenId].push(
            Checkpoint({
                timestamp: uint64(block.timestamp),
                heightCm: heightCm,
                healthScore: healthScore,
                status: status,
                actor: msg.sender,
                evidenceHash: evidenceHash,
                evidenceURI: evidenceURI
            })
        );
        emit CheckpointRecorded(
            tokenId, _checkpoints[tokenId].length - 1, status, heightCm, healthScore, msg.sender
        );
    }
}
