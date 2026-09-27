// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ImpactNFTBase
/// @notice Base común para los NFTs de impacto ambiental de ToKlean.
/// @dev - Roles con AccessControl (el admin debería ser un Safe multisig o el Timelock de gobernanza).
///      - Pausa de emergencia que bloquea mint, transferencias y registro de evidencias.
///      - Metadata 100% on-chain (JSON en base64); sólo la imagen apunta a `imageBaseURI`.
///      - Las evidencias se guardan como hash (keccak256/sha256 del archivo) + URI (IPFS/Arweave).
abstract contract ImpactNFTBase is ERC721, AccessControl, Pausable {
    using Strings for uint256;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Validadores/auditores independientes (ONGs, municipios, certificadoras).
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    uint256 private _nextTokenId = 1;
    string public imageBaseURI;

    event ImageBaseURIUpdated(string uri);

    error ZeroAddress();
    error EmptyEvidence();
    error EmptyString();
    error InvalidCoordinates();
    error NotTokenOwner(uint256 tokenId, address caller);
    error SelfVerification(uint256 tokenId, address verifier);

    constructor(string memory name_, string memory symbol_, address admin, string memory imageBaseURI_)
        ERC721(name_, symbol_)
    {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        imageBaseURI = imageBaseURI_;
    }

    // ------------------------------------------------------------------ admin

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setImageBaseURI(string calldata uri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        imageBaseURI = uri;
        emit ImageBaseURIUpdated(uri);
    }

    // ------------------------------------------------------------------ views

    function totalMinted() public view returns (uint256) {
        return _nextTokenId - 1;
    }

    function exists(uint256 tokenId) public view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory json = string.concat(
            '{"name":"',
            Strings.escapeJSON(_tokenName(tokenId)),
            '","description":"',
            Strings.escapeJSON(_tokenDescription(tokenId)),
            '","image":"',
            Strings.escapeJSON(string.concat(imageBaseURI, _imageKey(tokenId))),
            '","attributes":[',
            _attributes(tokenId),
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // --------------------------------------------------------------- hooks

    function _tokenName(uint256 tokenId) internal view virtual returns (string memory);
    function _tokenDescription(uint256 tokenId) internal view virtual returns (string memory);
    function _imageKey(uint256 tokenId) internal view virtual returns (string memory);
    function _attributes(uint256 tokenId) internal view virtual returns (string memory);

    /// @dev Pausa global de movimientos de tokens (mint, transfer, burn).
    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override
        whenNotPaused
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    // ------------------------------------------------------------- helpers

    /// @dev Usa `_mint` (no `_safeMint`) para evitar callbacks de reentrada durante el registro.
    function _mintNext(address to) internal returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _mint(to, tokenId);
    }

    function _requireTokenOwner(uint256 tokenId) internal view {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId, msg.sender);
    }

    function _requireEvidence(bytes32 evidenceHash) internal pure {
        if (evidenceHash == bytes32(0)) revert EmptyEvidence();
    }

    function _requireNonEmpty(string calldata value) internal pure {
        if (bytes(value).length == 0) revert EmptyString();
    }

    function _checkCoordinates(int32 latE6, int32 lonE6) internal pure {
        if (latE6 < -90e6 || latE6 > 90e6 || lonE6 < -180e6 || lonE6 > 180e6) revert InvalidCoordinates();
    }

    function _attr(string memory trait, string memory value) internal pure returns (string memory) {
        return string.concat('{"trait_type":"', trait, '","value":"', Strings.escapeJSON(value), '"}');
    }

    function _attrNum(string memory trait, uint256 value) internal pure returns (string memory) {
        return string.concat('{"trait_type":"', trait, '","value":', value.toString(), "}");
    }

    function _attrDate(string memory trait, uint256 timestamp) internal pure returns (string memory) {
        return string.concat(
            '{"display_type":"date","trait_type":"', trait, '","value":', timestamp.toString(), "}"
        );
    }

    /// @dev Formatea un entero escalado 1e6 (p.ej. coordenadas) como decimal: -33456789 -> "-33.456789".
    function _formatE6(int256 value) internal pure returns (string memory) {
        uint256 abs = value < 0 ? uint256(-value) : uint256(value);
        string memory frac = (abs % 1e6).toString();
        while (bytes(frac).length < 6) {
            frac = string.concat("0", frac);
        }
        return string.concat(value < 0 ? "-" : "", (abs / 1e6).toString(), ".", frac);
    }
}
