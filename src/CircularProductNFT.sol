// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ImpactNFTBase} from "./common/ImpactNFTBase.sol";
import {IRecyclingBatch} from "./interfaces/IRecyclingBatch.sol";

/// @title CircularProductNFT
/// @notice Pasaporte digital de producto (DPP) fabricado con material reciclado trazado.
///         Guarda de qué lotes (`RecyclingBatchNFT`) proviene, cuánto material usó y los datos
///         de fabricación limpia (energía, % renovable, agua, huella CO2e, residuos, reporte ACV).
/// @dev - Al fabricar se descuenta on-chain el material de cada lote: no se puede "gastar" dos veces.
///      - La certificación de fabricación limpia exige (a) cumplir criterios on-chain y (b) la firma de un
///        auditor independiente (VERIFIER_ROLE). Puede revocarse.
///      - El NFT sigue al producto físico (transferible) y el dueño puede declarar su retorno para reciclaje.
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

    struct ManufacturingData {
        uint64 energyWh;
        uint64 waterLiters;
        uint64 co2eGrams;
        uint64 wasteGrams;
        uint16 renewableEnergyBps;
        bytes32 reportHash;
        string reportURI;
        string facility;
    }

    struct Product {
        address manufacturer;
        uint64 manufacturedAt;
        uint96 massGrams;
        uint96 recycledGrams;
        CleanStatus status;
        bool returnedForRecycling;
        uint256 inspiredByIdea;
        string name;
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

    mapping(uint256 => Product) private _products;
    mapping(uint256 => ManufacturingData) private _data;
    mapping(uint256 => MaterialInput[]) private _inputs;
    mapping(address => uint256) public recycledGramsUsedBy;

    event ProductManufactured(
        uint256 indexed tokenId,
        address indexed manufacturer,
        address indexed to,
        uint96 massGrams,
        uint96 recycledGrams,
        uint256 inspiredByIdea
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
    event ReturnedForRecycling(uint256 indexed tokenId, address indexed owner);

    error NoInputs();
    error TooManyInputs();
    error InvalidMass();
    error InvalidBps(uint256 value);
    error RecycledExceedsMass(uint96 recycled, uint96 mass);
    error IdeasContractNotSet();
    error InvalidStatus(uint256 tokenId, CleanStatus current);
    error CriteriaNotMet(uint256 tokenId);
    error AlreadyReturned(uint256 tokenId);

    constructor(
        address admin,
        string memory imageBaseURI_,
        IRecyclingBatch batches_,
        IERC721 ideas_,
        CleanCriteria memory criteria_
    ) ImpactNFTBase("ToKlean Circular Product", "TKPROD", admin, imageBaseURI_) {
        if (address(batches_) == address(0)) revert ZeroAddress();
        batches = batches_;
        ideas = ideas_;
        _setCriteria(criteria_);
    }

    // ------------------------------------------------------------ actions

    function manufacture(
        address to,
        string calldata name,
        uint96 massGrams,
        MaterialInput[] calldata inputs,
        ManufacturingData calldata data,
        uint256 inspiredByIdea
    ) external onlyRole(MANUFACTURER_ROLE) whenNotPaused returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        _requireNonEmpty(name);
        if (massGrams == 0) revert InvalidMass();
        if (inputs.length == 0) revert NoInputs();
        if (inputs.length > MAX_INPUTS) revert TooManyInputs();
        if (data.renewableEnergyBps > BPS) revert InvalidBps(data.renewableEnergyBps);
        _requireEvidence(data.reportHash);
        if (inspiredByIdea != 0) {
            if (address(ideas) == address(0)) revert IdeasContractNotSet();
            ideas.ownerOf(inspiredByIdea); // revierte si la idea no existe
        }

        tokenId = _mintNext(to);

        uint96 recycled;
        MaterialInput[] storage stored = _inputs[tokenId];
        for (uint256 k; k < inputs.length; ++k) {
            MaterialInput calldata input = inputs[k];
            // `batches` es un contrato inmutable de confianza; revierte si el lote no es del fabricante,
            // no está procesado o no tiene material suficiente.
            batches.consume(input.batchId, input.grams, msg.sender, tokenId);
            recycled += input.grams;
            stored.push(input);
        }
        if (recycled > massGrams) revert RecycledExceedsMass(recycled, massGrams);

        Product storage p = _products[tokenId];
        p.manufacturer = msg.sender;
        p.manufacturedAt = uint64(block.timestamp);
        p.massGrams = massGrams;
        p.recycledGrams = recycled;
        p.inspiredByIdea = inspiredByIdea;
        p.name = name;
        _data[tokenId] = data;
        recycledGramsUsedBy[msg.sender] += recycled;

        emit ProductManufactured(tokenId, msg.sender, to, massGrams, recycled, inspiredByIdea);
    }

    function certify(uint256 tokenId, bool approved, bytes32 evidenceHash, string calldata evidenceURI)
        external
        onlyRole(VERIFIER_ROLE)
        whenNotPaused
    {
        Product storage p = _product(tokenId);
        if (msg.sender == p.manufacturer) revert SelfVerification(tokenId, msg.sender);
        if (p.status != CleanStatus.Declared) revert InvalidStatus(tokenId, p.status);
        _requireEvidence(evidenceHash);
        if (approved && !meetsCleanCriteria(tokenId)) revert CriteriaNotMet(tokenId);

        p.status = approved ? CleanStatus.Certified : CleanStatus.Rejected;
        emit CleanStatusChanged(tokenId, p.status, msg.sender, evidenceHash, evidenceURI);
    }

    function revokeCertification(uint256 tokenId, bytes32 evidenceHash, string calldata evidenceURI)
        external
        onlyRole(VERIFIER_ROLE)
        whenNotPaused
    {
        Product storage p = _product(tokenId);
        if (p.status != CleanStatus.Certified) revert InvalidStatus(tokenId, p.status);
        _requireEvidence(evidenceHash);
        p.status = CleanStatus.Revoked;
        emit CleanStatusChanged(tokenId, CleanStatus.Revoked, msg.sender, evidenceHash, evidenceURI);
    }

    /// @notice El dueño declara que entregó el producto para reciclaje (cierre del ciclo).
    function returnForRecycling(uint256 tokenId) external whenNotPaused {
        _requireTokenOwner(tokenId);
        Product storage p = _products[tokenId];
        if (p.returnedForRecycling) revert AlreadyReturned(tokenId);
        p.returnedForRecycling = true;
        emit ReturnedForRecycling(tokenId, msg.sender);
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

    function getInputs(uint256 tokenId) external view returns (MaterialInput[] memory) {
        _requireOwned(tokenId);
        return _inputs[tokenId];
    }

    function recycledContentBps(uint256 tokenId) public view returns (uint256) {
        Product storage p = _product(tokenId);
        return uint256(p.recycledGrams) * BPS / p.massGrams;
    }

    function co2eGramsPerKg(uint256 tokenId) public view returns (uint256) {
        Product storage p = _product(tokenId);
        return uint256(_data[tokenId].co2eGrams) * 1000 / p.massGrams;
    }

    function meetsCleanCriteria(uint256 tokenId) public view returns (bool) {
        CleanCriteria memory c = criteria;
        return recycledContentBps(tokenId) >= c.minRecycledContentBps
            && _data[tokenId].renewableEnergyBps >= c.minRenewableEnergyBps
            && co2eGramsPerKg(tokenId) <= c.maxCo2eGramsPerKg;
    }

    function statusName(CleanStatus s) public pure returns (string memory) {
        string[4] memory names =
            ["Declarado", "Fabricacion limpia certificada", "No certificado", "Certificacion revocada"];
        return names[uint256(s)];
    }

    // ------------------------------------------------------------ metadata

    function _tokenName(uint256 tokenId) internal view override returns (string memory) {
        return string.concat("Producto circular #", tokenId.toString(), " - ", _products[tokenId].name);
    }

    function _tokenDescription(uint256) internal pure override returns (string memory) {
        return "Pasaporte digital de un producto fabricado con material reciclado trazado en ToKlean.";
    }

    function _imageKey(uint256 tokenId) internal view override returns (string memory) {
        return _products[tokenId].status == CleanStatus.Certified ? "product-certified.svg" : "product.svg";
    }

    function _attributes(uint256 tokenId) internal view override returns (string memory) {
        Product storage p = _products[tokenId];
        ManufacturingData storage d = _data[tokenId];
        string memory a = string.concat(
            _attr("Estado", statusName(p.status)),
            ",",
            _attr("Planta", d.facility),
            ",",
            _attrNum("Masa (g)", p.massGrams),
            ",",
            _attrNum("Contenido reciclado (bps)", recycledContentBps(tokenId)),
            ",",
            _attrNum("Energia renovable (bps)", d.renewableEnergyBps),
            ","
        );
        return string.concat(
            a,
            _attrNum("CO2e (g/kg)", co2eGramsPerKg(tokenId)),
            ",",
            _attrNum("Agua (L)", d.waterLiters),
            ",",
            _attrNum("Lotes de origen", _inputs[tokenId].length),
            ",",
            _attr("Retornado a reciclaje", p.returnedForRecycling ? "Si" : "No"),
            ",",
            _attrDate("Fabricado", p.manufacturedAt)
        );
    }

    // ------------------------------------------------------------ internal

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
