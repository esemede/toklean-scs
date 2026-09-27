// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ImpactNFTBase} from "./common/ImpactNFTBase.sol";
import {IERC5192} from "./interfaces/IERC5192.sol";

/// @title CleanupActionNFT
/// @notice Insignias soulbound (ERC-5192) que acreditan participación verificada en jornadas de limpieza
///         (playas, ríos, quebradas, plazas) y los kilos recolectados por cada participante.
/// @dev Flujo:
///      1. ORGANIZER_ROLE crea la campaña (lugar, fechas).
///      2. Tras la jornada, un VERIFIER (distinto del organizador) publica el Merkle root de
///         (participante, campaña, gramos) + total pesado + evidencia.
///      3. Cada participante (o un relayer que pague el gas) reclama su insignia con su prueba Merkle.
///      La suma reclamada nunca puede superar el total pesado. Las insignias no se transfieren; el dueño puede quemarlas.
contract CleanupActionNFT is ImpactNFTBase, IERC5192 {
    using Strings for uint256;

    bytes32 public constant ORGANIZER_ROLE = keccak256("ORGANIZER_ROLE");

    struct Campaign {
        address organizer;
        uint64 startsAt;
        uint64 endsAt;
        int32 latE6;
        int32 lonE6;
        bool finalized;
        uint32 claims;
        uint96 totalGrams;
        uint96 claimedGrams;
        bytes32 merkleRoot;
        bytes32 evidenceHash;
        string name;
        string location;
        string evidenceURI;
    }

    struct Badge {
        uint256 campaignId;
        uint96 grams;
    }

    uint256 public campaignCount;
    mapping(uint256 => Campaign) private _campaigns;
    mapping(uint256 => Badge) public badges;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(address => uint256) public gramsCollectedBy;
    mapping(address => uint256) public actionsBy;

    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed organizer,
        string name,
        string location,
        uint64 startsAt,
        uint64 endsAt
    );
    event CampaignFinalized(
        uint256 indexed campaignId,
        address indexed verifier,
        bytes32 merkleRoot,
        uint96 totalGrams,
        bytes32 evidenceHash
    );
    event BadgeClaimed(
        uint256 indexed tokenId, uint256 indexed campaignId, address indexed participant, uint96 grams
    );

    error CampaignNotFound(uint256 campaignId);
    error InvalidPeriod();
    error CampaignNotEnded(uint256 campaignId);
    error CampaignAlreadyFinalized(uint256 campaignId);
    error CampaignNotFinalized(uint256 campaignId);
    error AlreadyClaimed(uint256 campaignId, address participant);
    error InvalidProof();
    error ClaimExceedsTotal(uint96 remaining, uint96 requested);
    error Soulbound();

    constructor(address admin, string memory imageBaseURI_)
        ImpactNFTBase("ToKlean Cleanup Action", "TKCLEAN", admin, imageBaseURI_)
    {}

    // ------------------------------------------------------------ actions

    function createCampaign(
        string calldata name,
        string calldata location,
        int32 latE6,
        int32 lonE6,
        uint64 startsAt,
        uint64 endsAt
    ) external onlyRole(ORGANIZER_ROLE) whenNotPaused returns (uint256 campaignId) {
        _requireNonEmpty(name);
        _checkCoordinates(latE6, lonE6);
        if (endsAt <= startsAt) revert InvalidPeriod();

        campaignId = ++campaignCount;
        Campaign storage c = _campaigns[campaignId];
        c.organizer = msg.sender;
        c.startsAt = startsAt;
        c.endsAt = endsAt;
        c.latE6 = latE6;
        c.lonE6 = lonE6;
        c.name = name;
        c.location = location;
        emit CampaignCreated(campaignId, msg.sender, name, location, startsAt, endsAt);
    }

    function finalizeCampaign(
        uint256 campaignId,
        bytes32 merkleRoot,
        uint96 totalGrams,
        bytes32 evidenceHash,
        string calldata evidenceURI
    ) external onlyRole(VERIFIER_ROLE) whenNotPaused {
        Campaign storage c = _campaign(campaignId);
        if (c.finalized) revert CampaignAlreadyFinalized(campaignId);
        if (block.timestamp < c.endsAt) revert CampaignNotEnded(campaignId);
        if (msg.sender == c.organizer) revert SelfVerification(campaignId, msg.sender);
        if (merkleRoot == bytes32(0)) revert InvalidProof();
        _requireEvidence(evidenceHash);

        c.finalized = true;
        c.merkleRoot = merkleRoot;
        c.totalGrams = totalGrams;
        c.evidenceHash = evidenceHash;
        c.evidenceURI = evidenceURI;
        emit CampaignFinalized(campaignId, msg.sender, merkleRoot, totalGrams, evidenceHash);
    }

    /// @notice Reclama la insignia de `participant`. Cualquiera puede llamarla (relayer), pero el NFT
    ///         siempre se acuña al participante incluido en el Merkle tree.
    /// @dev Hoja = keccak256(bytes.concat(keccak256(abi.encode(participant, campaignId, grams)))),
    ///      compatible con `StandardMerkleTree` de la libreria openzeppelin merkle-tree (JS).
    function claim(address participant, uint256 campaignId, uint96 grams, bytes32[] calldata proof)
        external
        whenNotPaused
        returns (uint256 tokenId)
    {
        Campaign storage c = _campaign(campaignId);
        if (!c.finalized) revert CampaignNotFinalized(campaignId);
        if (hasClaimed[campaignId][participant]) revert AlreadyClaimed(campaignId, participant);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(participant, campaignId, grams))));
        if (!MerkleProof.verifyCalldata(proof, c.merkleRoot, leaf)) revert InvalidProof();
        uint96 remaining = c.totalGrams - c.claimedGrams;
        if (grams > remaining) revert ClaimExceedsTotal(remaining, grams);

        hasClaimed[campaignId][participant] = true;
        c.claimedGrams += grams;
        unchecked {
            c.claims++;
            actionsBy[participant]++;
        }
        gramsCollectedBy[participant] += grams;

        tokenId = _mintNext(participant);
        badges[tokenId] = Badge({campaignId: campaignId, grams: grams});
        emit Locked(tokenId);
        emit BadgeClaimed(tokenId, campaignId, participant, grams);
    }

    /// @notice El titular puede quemar su insignia (p.ej. privacidad). Las estadísticas acumuladas no cambian.
    function burn(uint256 tokenId) external {
        _requireTokenOwner(tokenId);
        _burn(tokenId);
    }

    // -------------------------------------------------------------- views

    function getCampaign(uint256 campaignId) external view returns (Campaign memory) {
        return _campaign(campaignId);
    }

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------ metadata

    function _tokenName(uint256 tokenId) internal view override returns (string memory) {
        return string.concat(
            "Limpieza ToKlean #", tokenId.toString(), " - ", _campaigns[badges[tokenId].campaignId].name
        );
    }

    function _tokenDescription(uint256) internal pure override returns (string memory) {
        return "Insignia intransferible por participar en una accion de limpieza verificada por ToKlean.";
    }

    function _imageKey(uint256) internal pure override returns (string memory) {
        return "cleanup.svg";
    }

    function _attributes(uint256 tokenId) internal view override returns (string memory) {
        Badge storage b = badges[tokenId];
        Campaign storage c = _campaigns[b.campaignId];
        return string.concat(
            _attr("Campania", c.name),
            ",",
            _attr("Lugar", c.location),
            ",",
            _attrNum("Gramos recolectados", b.grams),
            ",",
            _attrNum("Participantes", c.claims),
            ",",
            _attrDate("Fecha", c.startsAt)
        );
    }

    // ------------------------------------------------------------ internal

    function _campaign(uint256 campaignId) internal view returns (Campaign storage c) {
        c = _campaigns[campaignId];
        if (c.organizer == address(0)) revert CampaignNotFound(campaignId);
    }

    /// @dev Soulbound: sólo se permite mint y burn.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }
}
