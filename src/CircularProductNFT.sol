// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ImpactNFTBase} from "./common/ImpactNFTBase.sol";
import {IRecyclingBatch} from "./interfaces/IRecyclingBatch.sol";
import {EnergyFactors, EnergyType, EnergyUse} from "./product/EnergyFactors.sol";

/// @title CircularProductNFT
/// @notice Pasaporte digital de producto (DPP) fabricado con material reciclado trazado.
///         Guarda de qué lotes (`RecyclingBatchNFT`) proviene, cuánto material usó y los datos
///         de fabricación limpia (energía por tipo, % renovable, agua, huella CO2e, residuos, reporte ACV).
/// @dev v2: la energía se declara por tipo y cantidad (`EnergyUse`) y el contrato calcula el % renovable y las
///      emisiones de la energía con una tabla de factores (gCO2e/kWh) en vez de confiar en cifras del fabricante.
/// @dev - Al fabricar se descuenta on-chain el material de cada lote: no se puede "gastar" dos veces.
///      - La certificación de fabricación limpia exige (a) cumplir criterios on-chain y (b) la firma de un
///        auditor independiente (VERIFIER_ROLE). Puede revocarse.
///      - El pasaporte se queda en custodia (Catalog -> LivingProduct); el cierre del ciclo (recuperación REP) se registra
///        en `LivingProduct`.
contract CircularProductNFT is ImpactNFTBase {
    using Strings for uint256;

    bytes32 public constant MANUFACTURER_ROLE = keccak256("MANUFACTURER_ROLE");

    uint256 public constant MAX_INPUTS = 20;
    uint16 internal constant BPS = 10_000;

    enum CleanStatus {
        Declared,
        Certified,
        Rejected,
        Revoked
    }

    struct MaterialInput {
        uint256 batchId;
        uint96 grams;
    }

    /// @notice Lo que declara el fabricante. La energía y sus emisiones se calculan aparte (`EnergyUse`).
    struct ManufacturingInput {
        uint64 waterLiters;
        uint64 processCo2eGrams; // emisiones del proceso y materiales, sin la energía
        uint64 wasteGrams;
        bytes32 reportHash;
        string reportURI; // informe ACV: incluye la planta y la metodología
    }

    /// @notice Datos guardados: la energía y el % renovable son calculados, `co2eGrams` es proceso + energía.
    struct ManufacturingData {
        uint64 energyWh;
        uint64 waterLiters;
        uint64 co2eGrams;
        uint64 wasteGrams;
        uint16 renewableEnergyBps;
        bytes32 reportHash;
    }

    struct Product {
        address manufacturer;
        uint64 manufacturedAt;
        uint96 massGrams;
        uint96 recycledGrams;
        CleanStatus status;
        uint256 inspiredByIdea;
    }

    struct CleanCriteria {
        uint16 minRecycledContentBps;
        uint16 minRenewableEnergyBps;
        uint64 maxCo2eGramsPerKg;
    }

    IRecyclingBatch public immutable batches;
    /// @notice Contrato `RecyclingIdeaNFT` (opcional, puede ser address(0)).
    IERC721 public immutable ideas;
    CleanCriteria public criteria;
    /// @notice Tabla de factores de emisión de la energía (la edita su admin, p. ej. por gobernanza).
    EnergyFactors public immutable energyFactors;

    mapping(uint256 => Product) private _products;
    mapping(uint256 => ManufacturingData) private _data;

    event ProductManufactured(
        uint256 indexed tokenId,
        address indexed manufacturer,
        address indexed to,
        uint96 massGrams,
        uint96 recycledGrams,
        uint256 inspiredByIdea,
        string name,
        string reportURI
    );
    event CleanStatusChanged(
        uint256 indexed tokenId,
        CleanStatus status,
        address indexed auditor,
        bytes32 evidenceHash,
        string evidenceURI
    );
    event CriteriaUpdated(
        uint16 minRecycledContentBps, uint16 minRenewableEnergyBps, uint64 maxCo2eGramsPerKg
    );
    event MaterialUsed(uint256 indexed tokenId, uint256 indexed batchId, uint96 grams);
    event EnergyUsed(uint256 indexed tokenId, EnergyType kind, uint64 wh);
    event EnergyRecorded(
        uint256 indexed tokenId, uint64 energyWh, uint64 energyCo2eGrams, uint16 renewableEnergyBps
    );

    error NoInputs();
    error Overflow();
    error TooManyInputs();
    error InvalidMass();
    error InvalidBps(uint256 value);
    error RecycledExceedsMass(uint96 recycled, uint96 mass);
    error IdeasContractNotSet();
    error InvalidStatus(uint256 tokenId, CleanStatus current);
    error CriteriaNotMet(uint256 tokenId);

    constructor(
        address admin,
        string memory imageBaseURI_,
        IRecyclingBatch batches_,
        IERC721 ideas_,
        EnergyFactors energyFactors_,
        CleanCriteria memory criteria_
    ) ImpactNFTBase("ToKlean Circular Product", "TKPROD", admin, imageBaseURI_) {
        if (address(batches_) == address(0) || address(energyFactors_) == address(0)) revert ZeroAddress();
        batches = batches_;
        ideas = ideas_;
        energyFactors = energyFactors_;
        _setCriteria(criteria_);
    }

    // ------------------------------------------------------------ actions

    function manufacture(
        address to,
        string calldata name,
        uint96 massGrams,
        MaterialInput[] calldata inputs,
        EnergyUse[] calldata energy,
        ManufacturingInput calldata data,
        uint256 inspiredByIdea
    ) external onlyRole(MANUFACTURER_ROLE) whenNotPaused returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        _requireNonEmpty(name);
        if (massGrams == 0) revert InvalidMass();
        if (inputs.length == 0) revert NoInputs();
        if (inputs.length > MAX_INPUTS) revert TooManyInputs();
        _requireEvidence(data.reportHash);
        if (inspiredByIdea != 0) {
            if (address(ideas) == address(0)) revert IdeasContractNotSet();
            ideas.ownerOf(inspiredByIdea); // revierte si la idea no existe
        }

        tokenId = _mintNext(to);

        uint96 recycled;
        for (uint256 k; k < inputs.length; ++k) {
            MaterialInput calldata input = inputs[k];
            // `batches` es un contrato inmutable de confianza; revierte si el lote no es del fabricante,
            // no está procesado o no tiene material suficiente.
            batches.consume(input.batchId, input.grams, msg.sender, tokenId);
            recycled += input.grams;
            emit MaterialUsed(tokenId, input.batchId, input.grams);
        }
        if (recycled > massGrams) revert RecycledExceedsMass(recycled, massGrams);

        Product storage p = _products[tokenId];
        p.manufacturer = msg.sender;
        p.manufacturedAt = uint64(block.timestamp);
        p.massGrams = massGrams;
        p.recycledGrams = recycled;
        p.inspiredByIdea = inspiredByIdea;
        _storeData(tokenId, energy, data);

        emit ProductManufactured(
            tokenId, msg.sender, to, massGrams, recycled, inspiredByIdea, name, data.reportURI
        );
    }

    /// @notice Un auditor (distinto del fabricante) decide sobre el producto. `approved` certifica si cumple los
    ///         criterios; `!approved` rechaza un producto declarado o revoca uno ya certificado.
    function certify(uint256 tokenId, bool approved, bytes32 evidenceHash, string calldata evidenceURI)
        external
        onlyRole(VERIFIER_ROLE)
        whenNotPaused
    {
        Product storage p = _product(tokenId);
        if (msg.sender == p.manufacturer) revert SelfVerification(tokenId, msg.sender);
        _requireEvidence(evidenceHash);
        CleanStatus current = p.status;
        if (approved) {
            if (current != CleanStatus.Declared) revert InvalidStatus(tokenId, current);
            if (!meetsCleanCriteria(tokenId)) revert CriteriaNotMet(tokenId);
            p.status = CleanStatus.Certified;
        } else if (current == CleanStatus.Declared) {
            p.status = CleanStatus.Rejected;
        } else if (current == CleanStatus.Certified) {
            p.status = CleanStatus.Revoked;
        } else {
            revert InvalidStatus(tokenId, current);
        }
        emit CleanStatusChanged(tokenId, p.status, msg.sender, evidenceHash, evidenceURI);
    }

    function setCriteria(CleanCriteria calldata criteria_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCriteria(criteria_);
    }

    // -------------------------------------------------------------- views

    function getProduct(uint256 tokenId) external view returns (Product memory) {
        return _product(tokenId);
    }

    function getManufacturingData(uint256 tokenId) external view returns (ManufacturingData memory) {
        _requireOwned(tokenId);
        return _data[tokenId];
    }

    /// @notice Estado de certificación (lectura barata para otros contratos).
    function statusOf(uint256 tokenId) external view returns (CleanStatus) {
        return _product(tokenId).status;
    }

    /// @notice Fabricante del producto (lectura barata para otros contratos).
    function manufacturerOf(uint256 tokenId) external view returns (address) {
        return _product(tokenId).manufacturer;
    }

    function _recycledBps(uint256 tokenId) internal view returns (uint256) {
        Product storage p = _product(tokenId);
        return uint256(p.recycledGrams) * BPS / p.massGrams;
    }

    function _co2ePerKg(uint256 tokenId) internal view returns (uint256) {
        Product storage p = _product(tokenId);
        return uint256(_data[tokenId].co2eGrams) * 1000 / p.massGrams;
    }

    function meetsCleanCriteria(uint256 tokenId) public view returns (bool) {
        CleanCriteria memory c = criteria;
        return _recycledBps(tokenId) >= c.minRecycledContentBps
            && _data[tokenId].renewableEnergyBps >= c.minRenewableEnergyBps
            && _co2ePerKg(tokenId) <= c.maxCo2eGramsPerKg;
    }

    // ------------------------------------------------------------ metadata

    /// @dev Se omite el JSON on-chain de la base (pesa ~3 KB y no cabe en el tope de gas de Sepolia): los datos
    ///      del pasaporte se leen con `getProduct` y `getManufacturingData`; la energía y los lotes de origen se
    ///      registran en los eventos `EnergyUsed` y `MaterialUsed`.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return imageBaseURI;
    }

    function _tokenName(uint256) internal pure override returns (string memory) {
        return "";
    }

    function _tokenDescription(uint256) internal pure override returns (string memory) {
        return "";
    }

    function _imageKey(uint256) internal pure override returns (string memory) {
        return "";
    }

    function _attributes(uint256) internal pure override returns (string memory) {
        return "";
    }

    // ------------------------------------------------------------ internal

    function _storeData(uint256 tokenId, EnergyUse[] calldata energy, ManufacturingInput calldata data)
        private
    {
        (uint64 totalWh, uint64 energyCo2e, uint16 renewableBps) = energyFactors.totals(energy);
        uint256 total = uint256(energyCo2e) + data.processCo2eGrams;
        if (total > type(uint64).max) revert Overflow();
        ManufacturingData storage d = _data[tokenId];
        d.energyWh = totalWh;
        d.waterLiters = data.waterLiters;
        d.co2eGrams = uint64(total);
        d.wasteGrams = data.wasteGrams;
        d.renewableEnergyBps = renewableBps;
        d.reportHash = data.reportHash;
        for (uint256 i; i < energy.length; ++i) {
            emit EnergyUsed(tokenId, energy[i].kind, energy[i].wh);
        }
        emit EnergyRecorded(tokenId, totalWh, energyCo2e, renewableBps);
    }

    function _product(uint256 tokenId) internal view returns (Product storage) {
        _requireOwned(tokenId);
        return _products[tokenId];
    }

    function _setCriteria(CleanCriteria memory c) internal {
        if (c.minRecycledContentBps > BPS) revert InvalidBps(c.minRecycledContentBps);
        if (c.minRenewableEnergyBps > BPS) revert InvalidBps(c.minRenewableEnergyBps);
        criteria = c;
        emit CriteriaUpdated(c.minRecycledContentBps, c.minRenewableEnergyBps, c.maxCo2eGramsPerKg);
    }
}
