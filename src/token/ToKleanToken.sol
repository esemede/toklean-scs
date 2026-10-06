// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC1155Burnable} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title ToKleanToken
/// @notice Contrato ERC-1155 único para la economía de ToKlean (un id por token, 18 decimales).
///         - TKN (id 1): token de utilidad y gobernanza, con tope de suministro. Se hace stake para votar.
///         - REC (id 2): recompensa liquida del juego y del staking. Sin tope, se quema en los sinks del juego.
///         - POR (id 3): Prueba de Reciclaje, emitida al comprar productos reciclados.
/// @dev El admin debería ser el Timelock/Governance (o un Safe multisig). Minters: staking, faucet de testnet,
///      oráculo/juego. La pausa de emergencia bloquea toda transferencia, emisión y quema.
contract ToKleanToken is ERC1155, ERC1155Supply, ERC1155Burnable, AccessControl, Pausable {
    uint256 public constant TKN = 1;
    uint256 public constant REC = 2;
    uint256 public constant POR = 3;
    uint8 public constant DECIMALS = 18;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    string public constant name = "ToKlean";
    string public constant symbol = "TOKLEAN";

    /// @notice Tope de suministro por id (0 = sin tope).
    mapping(uint256 id => uint256 cap) public maxSupply;

    event SupplyCapUpdated(uint256 indexed id, uint256 cap);

    error ZeroAddress();
    error InvalidTokenId(uint256 id);
    error CapExceeded(uint256 id, uint256 requested, uint256 cap);
    error CapBelowSupply(uint256 id, uint256 cap, uint256 supply);

    constructor(address admin, uint256 tknCap) ERC1155("") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        maxSupply[TKN] = tknCap;
        emit SupplyCapUpdated(TKN, tknCap);
    }

    // ------------------------------------------------------------------ emisión

    function mint(address to, uint256 id, uint256 amount) external onlyRole(MINTER_ROLE) {
        _requireValidId(id);
        _mint(to, id, amount, "");
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts)
        external
        onlyRole(MINTER_ROLE)
    {
        for (uint256 i = 0; i < ids.length; ++i) {
            _requireValidId(ids[i]);
        }
        _mintBatch(to, ids, amounts, "");
    }

    /// @notice Sólo se puede fijar un tope igual o mayor al suministro actual (0 = sin tope).
    function setMaxSupply(uint256 id, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireValidId(id);
        if (cap != 0 && cap < totalSupply(id)) revert CapBelowSupply(id, cap, totalSupply(id));
        maxSupply[id] = cap;
        emit SupplyCapUpdated(id, cap);
    }

    // ------------------------------------------------------------------ pausa

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ metadata

    /// @notice Metadata on-chain (JSON en base64) por id.
    function uri(uint256 id) public pure override returns (string memory) {
        _requireValidId(id);
        (string memory n, string memory s, string memory d) = _info(id);
        bytes memory json =
            abi.encodePacked('{"name":"', n, '","symbol":"', s, '","decimals":18,"description":"', d, '"}');
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function _info(uint256 id) private pure returns (string memory n, string memory s, string memory d) {
        if (id == TKN) {
            return (
                "ToKlean (TKN)",
                "TKN",
                "Token de utilidad y gobernanza de ToKlean. Se hace stake para votar y ganar REC."
            );
        }
        if (id == REC) {
            return (
                "ToKlean Reward (REC)",
                "REC",
                "Recompensa liquida por reciclar y por staking. Se quema en el juego."
            );
        }
        return (
            "Proof of Recycle (POR)",
            "POR",
            "Prueba de Reciclaje: certifica la compra de productos reciclados."
        );
    }

    // ------------------------------------------------------------------ internos

    function _requireValidId(uint256 id) private pure {
        if (id < TKN || id > POR) revert InvalidTokenId(id);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
        whenNotPaused
    {
        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                uint256 cap = maxSupply[ids[i]];
                // Con ids repetidos en un mismo lote cada elemento se revisa contra el suministro previo
                // más lo acumulado en la iteración, por eso se recalcula incluyendo los anteriores.
                if (cap != 0) {
                    uint256 pending;
                    for (uint256 j = 0; j <= i; ++j) {
                        if (ids[j] == ids[i]) pending += values[j];
                    }
                    if (totalSupply(ids[i]) + pending > cap) {
                        revert CapExceeded(ids[i], totalSupply(ids[i]) + pending, cap);
                    }
                }
            }
        }
        super._update(from, to, ids, values);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
