// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ImpactNFTBase} from "./common/ImpactNFTBase.sol";
import {MaterialType, MaterialNames} from "./common/Types.sol";
import {IRecyclingBatch} from "./interfaces/IRecyclingBatch.sol";

/// @title RecyclingBatchNFT
/// @notice "Pasaporte" NFT de un lote de material reciclable con cadena de custodia completa:
///         recolección -> centro de acopio -> clasificación -> planta recicladora -> material procesado
///         -> fabricante (que lo consume al fabricar un `CircularProductNFT`).
/// @dev - El NFT siempre lo posee el custodio físico actual. Las transferencias libres están bloqueadas:
///        sólo se mueve con el handshake `dispatch` (emisor) + `acceptBatch` (receptor que pesa el lote).
///      - Control de balance de masa: cada pesaje no puede superar el anterior más una tolerancia de báscula.
///      - RAEE y baterías (Ley REP) sólo pueden recibirlos gestores con HAZARDOUS_HANDLER_ROLE
///        (autorización sanitaria D.S. 148/2003) hasta que el material esté procesado.
contract RecyclingBatchNFT is ImpactNFTBase, IRecyclingBatch {
    using Strings for uint256;
    using MaterialNames for MaterialType;

    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 public constant COLLECTION_CENTER_ROLE = keccak256("COLLECTION_CENTER_ROLE");
    bytes32 public constant RECYCLER_ROLE = keccak256("RECYCLER_ROLE");
    bytes32 public constant MANUFACTURER_ROLE = keccak256("MANUFACTURER_ROLE");
    bytes32 public constant HAZARDOUS_HANDLER_ROLE = keccak256("HAZARDOUS_HANDLER_ROLE");
    /// @notice Contratos de producto autorizados a descontar material (p.ej. CircularProductNFT).
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE");

    /// @notice Tolerancia de báscula entre pesajes consecutivos (2 %).
    uint256 public constant WEIGHT_TOLERANCE_BPS = 200;

    enum Stage {
        Collected,
        AtCollectionCenter,
        Sorted,
        AtRecycler,
        Processed,
        AtManufacturer,
        Consumed,
        Rejected
    }

    struct Batch {
        MaterialType material;
        Stage stage;
        bool hazardous;
        uint64 createdAt;
        address collector;
        address pendingRecipient;
        uint96 declaredGrams;
        uint96 currentGrams;
        uint96 consumedGrams;
        string origin;
    }

    struct Step {
        Stage stage;
        address actor;
        uint64 timestamp;
        uint96 measuredGrams;
        bytes32 evidenceHash;
        string evidenceURI;
    }

    mapping(uint256 => Batch) private _batches;
    mapping(uint256 => Step[]) private _steps;

    /// @notice Kilos (en gramos) recolectados por cada recolector, según el pesaje del centro de acopio.
    mapping(address => uint256) public verifiedGramsByCollector;
    mapping(MaterialType => uint256) public processedGramsByMaterial;

    bool private transient _inHandoff;

    event BatchRegistered(
        uint256 indexed tokenId,
        address indexed collector,
        MaterialType indexed material,
        uint96 grams,
        string origin
    );
    event BatchDispatched(uint256 indexed tokenId, address indexed from, address indexed to, Stage stage);
    event DispatchCancelled(uint256 indexed tokenId, address indexed by);
    event StepRecorded(
        uint256 indexed tokenId,
        uint256 index,
        Stage indexed stage,
        address indexed actor,
        uint96 grams,
        bytes32 evidenceHash
    );
    event BatchConsumed(
        uint256 indexed tokenId, uint256 indexed productId, address indexed operator, uint96 grams
    );

    error InvalidStage(uint256 tokenId, Stage stage);
    error MissingRole(address account, bytes32 role);
    error NotPendingRecipient(uint256 tokenId, address caller);
    error NoPendingDispatch(uint256 tokenId);
    error InvalidWeight(uint96 grams);
    error WeightExceedsTolerance(uint96 previous, uint96 measured);
    error InsufficientMaterial(uint96 available, uint96 requested);
    error PartiallyConsumed(uint256 tokenId);
    error TransferOnlyViaHandoff();

    constructor(address admin, string memory imageBaseURI_)
        ImpactNFTBase("ToKlean Recycling Batch", "TKBATCH", admin, imageBaseURI_)
    {}

    // --------------------------------------------------------- collection

    function registerCollection(
        MaterialType material,
        uint96 grams,
        string calldata origin,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external onlyRole(COLLECTOR_ROLE) whenNotPaused returns (uint256 tokenId) {
        if (grams == 0) revert InvalidWeight(grams);
        _requireNonEmpty(origin);
        _requireEvidence(evidenceHash);

        tokenId = _mintNext(msg.sender);
        Batch storage b = _batches[tokenId];
        b.material = material;
        b.hazardous = material.isHazardous();
        b.createdAt = uint64(block.timestamp);
        b.collector = msg.sender;
        b.declaredGrams = grams;
        b.currentGrams = grams;
        b.origin = origin;
        // stage = Collected (0)

        emit BatchRegistered(tokenId, msg.sender, material, grams, origin);
        _pushStep(tokenId, Stage.Collected, grams, evidenceHash, evidenceURI);
    }

    // ------------------------------------------------------ custody handoff

    /// @notice El custodio actual anuncia a quién entrega el lote. La custodia cambia sólo cuando el receptor acepta.
    function dispatch(uint256 tokenId, address to) external whenNotPaused {
        _requireTokenOwner(tokenId);
        Batch storage b = _batches[tokenId];
        (bytes32 role,) = _nextHop(tokenId, b.stage);
        if (to == msg.sender || to == address(0)) revert ZeroAddress();
        if (!hasRole(role, to)) revert MissingRole(to, role);
        if (b.hazardous && b.stage != Stage.Processed && !hasRole(HAZARDOUS_HANDLER_ROLE, to)) {
            revert MissingRole(to, HAZARDOUS_HANDLER_ROLE);
        }
        if (b.stage == Stage.Processed && b.consumedGrams != 0) revert PartiallyConsumed(tokenId);

        b.pendingRecipient = to;
        emit BatchDispatched(tokenId, msg.sender, to, b.stage);
    }

    function cancelDispatch(uint256 tokenId) external whenNotPaused {
        _requireTokenOwner(tokenId);
        Batch storage b = _batches[tokenId];
        if (b.pendingRecipient == address(0)) revert NoPendingDispatch(tokenId);
        b.pendingRecipient = address(0);
        emit DispatchCancelled(tokenId, msg.sender);
    }

    /// @notice El receptor pesa el lote y acepta la custodia; el NFT se transfiere a su cuenta.
    function acceptBatch(
        uint256 tokenId,
        uint96 measuredGrams,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external whenNotPaused {
        Batch storage b = _batches[tokenId];
        if (b.pendingRecipient == address(0) || b.pendingRecipient != msg.sender) {
            revert NotPendingRecipient(tokenId, msg.sender);
        }
        (bytes32 role, Stage arrival) = _nextHop(tokenId, b.stage);
        if (!hasRole(role, msg.sender)) revert MissingRole(msg.sender, role);
        _checkWeight(b.currentGrams, measuredGrams, true);
        _requireEvidence(evidenceHash);

        address from = ownerOf(tokenId);
        b.pendingRecipient = address(0);
        b.stage = arrival;
        b.currentGrams = measuredGrams;
        if (arrival == Stage.AtCollectionCenter) {
            verifiedGramsByCollector[b.collector] += measuredGrams;
        }

        _inHandoff = true;
        _transfer(from, msg.sender, tokenId);
        _inHandoff = false;

        _pushStep(tokenId, arrival, measuredGrams, evidenceHash, evidenceURI);
    }

    // ------------------------------------------------------- processing

    /// @notice El centro de acopio clasifica/limpia el lote (el peso sólo puede bajar: se retiran impropios).
    function recordSorting(
        uint256 tokenId,
        uint96 sortedGrams,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external whenNotPaused {
        Batch storage b = _custodianBatch(tokenId, Stage.AtCollectionCenter, COLLECTION_CENTER_ROLE);
        _checkWeight(b.currentGrams, sortedGrams, false);
        _requireEvidence(evidenceHash);
        b.stage = Stage.Sorted;
        b.currentGrams = sortedGrams;
        _pushStep(tokenId, Stage.Sorted, sortedGrams, evidenceHash, evidenceURI);
    }

    /// @notice La planta recicladora registra el material de salida (pellet, fardo, lingote, fracciones RAEE...).
    function recordProcessing(
        uint256 tokenId,
        uint96 outputGrams,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external whenNotPaused {
        Batch storage b = _custodianBatch(tokenId, Stage.AtRecycler, RECYCLER_ROLE);
        _checkWeight(b.currentGrams, outputGrams, false);
        _requireEvidence(evidenceHash);
        b.stage = Stage.Processed;
        b.currentGrams = outputGrams;
        processedGramsByMaterial[b.material] += outputGrams;
        _pushStep(tokenId, Stage.Processed, outputGrams, evidenceHash, evidenceURI);
    }

    /// @notice Descarta un lote (contaminado, fraude, disposición final). Lo puede hacer un VERIFIER o el custodio.
    function reject(uint256 tokenId, bytes32 evidenceHash, string calldata evidenceURI)
        external
        whenNotPaused
    {
        _requireOwned(tokenId);
        Batch storage b = _batches[tokenId];
        if (!hasRole(VERIFIER_ROLE, msg.sender) && ownerOf(tokenId) != msg.sender) {
            revert MissingRole(msg.sender, VERIFIER_ROLE);
        }
        if (b.stage == Stage.Consumed || b.stage == Stage.Rejected || b.consumedGrams != 0) {
            revert InvalidStage(tokenId, b.stage);
        }
        _requireEvidence(evidenceHash);
        b.stage = Stage.Rejected;
        b.pendingRecipient = address(0);
        _pushStep(tokenId, Stage.Rejected, b.currentGrams, evidenceHash, evidenceURI);
    }

    /// @inheritdoc IRecyclingBatch
    function consume(uint256 tokenId, uint96 grams, address operator, uint256 productId)
        external
        onlyRole(CONSUMER_ROLE)
        whenNotPaused
    {
        if (ownerOf(tokenId) != operator) revert NotTokenOwner(tokenId, operator);
        Batch storage b = _batches[tokenId];
        if (b.stage != Stage.Processed && b.stage != Stage.AtManufacturer) {
            revert InvalidStage(tokenId, b.stage);
        }
        if (grams == 0) revert InvalidWeight(grams);
        uint96 available = b.currentGrams - b.consumedGrams;
        if (grams > available) revert InsufficientMaterial(available, grams);

        b.consumedGrams += grams;
        b.pendingRecipient = address(0);
        if (b.consumedGrams == b.currentGrams) b.stage = Stage.Consumed;
        emit BatchConsumed(tokenId, productId, operator, grams);
    }

    // -------------------------------------------------------------- views

    function getBatch(uint256 tokenId) external view returns (Batch memory) {
        _requireOwned(tokenId);
        return _batches[tokenId];
    }

    function getSteps(uint256 tokenId) external view returns (Step[] memory) {
        _requireOwned(tokenId);
        return _steps[tokenId];
    }

    function availableGrams(uint256 tokenId) external view returns (uint96) {
        _requireOwned(tokenId);
        Batch storage b = _batches[tokenId];
        if (b.stage != Stage.Processed && b.stage != Stage.AtManufacturer) return 0;
        return b.currentGrams - b.consumedGrams;
    }

    function materialOf(uint256 tokenId) external view returns (MaterialType) {
        _requireOwned(tokenId);
        return _batches[tokenId].material;
    }

    function stageName(Stage s) public pure returns (string memory) {
        string[8] memory names = [
            "Recolectado",
            "En centro de acopio",
            "Clasificado",
            "En planta recicladora",
            "Procesado",
            "En fabricante",
            "Consumido",
            "Rechazado"
        ];
        return names[uint256(s)];
    }

    // ------------------------------------------------------------ metadata

    function _tokenName(uint256 tokenId) internal view override returns (string memory) {
        return string.concat("Lote ToKlean #", tokenId.toString(), " - ", _batches[tokenId].material.name());
    }

    function _tokenDescription(uint256) internal pure override returns (string memory) {
        return
            "Pasaporte de trazabilidad de un lote de material reciclable: cadena de custodia y pesajes on-chain.";
    }

    function _imageKey(uint256 tokenId) internal view override returns (string memory) {
        return string.concat("batch-", uint256(_batches[tokenId].material).toString(), ".svg");
    }

    function _attributes(uint256 tokenId) internal view override returns (string memory) {
        Batch storage b = _batches[tokenId];
        string memory a = string.concat(
            _attr("Material", b.material.name()),
            ",",
            _attr("Etapa", stageName(b.stage)),
            ",",
            _attr("Peligroso", b.hazardous ? "Si" : "No"),
            ",",
            _attr("Origen", b.origin),
            ","
        );
        return string.concat(
            a,
            _attrNum("Peso declarado (g)", b.declaredGrams),
            ",",
            _attrNum("Peso actual (g)", b.currentGrams),
            ",",
            _attrNum("Consumido (g)", b.consumedGrams),
            ",",
            _attrNum("Pasos", _steps[tokenId].length),
            ",",
            _attrDate("Recolectado", b.createdAt)
        );
    }

    // ------------------------------------------------------------ internal

    function _nextHop(uint256 tokenId, Stage s) internal pure returns (bytes32 role, Stage arrival) {
        if (s == Stage.Collected) return (COLLECTION_CENTER_ROLE, Stage.AtCollectionCenter);
        if (s == Stage.Sorted) return (RECYCLER_ROLE, Stage.AtRecycler);
        if (s == Stage.Processed) return (MANUFACTURER_ROLE, Stage.AtManufacturer);
        revert InvalidStage(tokenId, s);
    }

    function _custodianBatch(uint256 tokenId, Stage expected, bytes32 role)
        internal
        view
        returns (Batch storage b)
    {
        _requireTokenOwner(tokenId);
        if (!hasRole(role, msg.sender)) revert MissingRole(msg.sender, role);
        b = _batches[tokenId];
        if (b.stage != expected) revert InvalidStage(tokenId, b.stage);
    }

    function _checkWeight(uint96 previous, uint96 measured, bool withTolerance) internal pure {
        if (measured == 0) revert InvalidWeight(measured);
        uint256 max =
            withTolerance ? uint256(previous) * (10_000 + WEIGHT_TOLERANCE_BPS) / 10_000 : uint256(previous);
        if (measured > max) revert WeightExceedsTolerance(previous, measured);
    }

    function _pushStep(
        uint256 tokenId,
        Stage stage,
        uint96 grams,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) internal {
        _steps[tokenId].push(
            Step({
                stage: stage,
                actor: msg.sender,
                timestamp: uint64(block.timestamp),
                measuredGrams: grams,
                evidenceHash: evidenceHash,
                evidenceURI: evidenceURI
            })
        );
        emit StepRecorded(tokenId, _steps[tokenId].length - 1, stage, msg.sender, grams, evidenceHash);
    }

    /// @dev Bloquea transferencias libres: la custodia sólo cambia vía dispatch/acceptBatch.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0) && !_inHandoff) revert TransferOnlyViaHandoff();
        return super._update(to, tokenId, auth);
    }
}
