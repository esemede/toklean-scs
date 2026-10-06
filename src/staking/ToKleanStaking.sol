// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {ToKleanToken} from "../token/ToKleanToken.sol";

/// @title ToKleanStaking
/// @notice Stake de TKN (ERC-1155 id 1) que rinde REC (id 2) a un APR lineal, y que además es la fuente del
///         poder de voto de la DAO (con historial para votar sobre un snapshot).
/// @dev - El APR se aplica por un índice acumulado global: un cambio de tasa NO es retroactivo.
///      - `unstake` funciona siempre (incluso en pausa); la pausa sólo bloquea `stake` y `claim`.
///      - Sólo acepta TKN enviado por `stake()` (rechaza transferencias directas que quedarían bloqueadas).
///      - Sin delegación de votos: el poder de voto es el TKN en stake de cada cuenta.
contract ToKleanStaking is ERC1155Holder, AccessControl, Pausable, ReentrancyGuard {
    using Checkpoints for Checkpoints.Trace208;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Quien puede cambiar el APR (idealmente la gobernanza/timelock).
    bytes32 public constant PARAMETERS_ROLE = keccak256("PARAMETERS_ROLE");

    uint16 public constant MAX_APR_BPS = 5000; // 50 %
    uint256 private constant YEAR = 365 days;
    uint256 private constant PRECISION = 1e18;

    ToKleanToken public immutable token;

    uint16 public aprBps;
    uint256 public rewardIndex; // REC (18 dec) acumulado por 1 TKN en stake, escala 1e18
    uint48 public indexUpdatedAt;
    uint256 public totalStaked;

    struct Position {
        uint128 staked;
        uint128 pending;
        uint256 indexPaid;
    }

    mapping(address account => Position) private _positions;
    mapping(address account => Checkpoints.Trace208) private _stakeHistory;
    Checkpoints.Trace208 private _totalHistory;

    event Staked(address indexed account, uint256 amount, uint256 newStake);
    event Unstaked(address indexed account, uint256 amount, uint256 newStake);
    event Claimed(address indexed account, uint256 amount);
    event AprUpdated(uint16 aprBps);

    error ZeroAddress();
    error ZeroAmount();
    error AprTooHigh(uint16 aprBps);
    error InsufficientStake(uint256 requested, uint256 available);
    error NothingToClaim();
    error DirectTransferNotAllowed();
    error FutureLookup(uint256 timepoint);

    constructor(ToKleanToken token_, address admin, uint16 initialAprBps) {
        if (address(token_) == address(0) || admin == address(0)) revert ZeroAddress();
        if (initialAprBps > MAX_APR_BPS) revert AprTooHigh(initialAprBps);
        token = token_;
        aprBps = initialAprBps;
        indexUpdatedAt = uint48(block.timestamp);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(PARAMETERS_ROLE, admin);
        emit AprUpdated(initialAprBps);
    }

    // ------------------------------------------------------------------ usuario

    /// @notice Requiere `setApprovalForAll(staking, true)` previo sobre el token.
    function stake(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage p = _accrue(msg.sender);
        uint256 newStake = p.staked + amount;
        _setStake(msg.sender, p, newStake, totalStaked + amount);
        token.safeTransferFrom(msg.sender, address(this), token.TKN(), amount, "");
        emit Staked(msg.sender, amount, newStake);
    }

    /// @notice Siempre disponible, incluso con el contrato en pausa.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage p = _accrue(msg.sender);
        if (amount > p.staked) revert InsufficientStake(amount, p.staked);
        uint256 newStake = p.staked - amount;
        _setStake(msg.sender, p, newStake, totalStaked - amount);
        token.safeTransferFrom(address(this), msg.sender, token.TKN(), amount, "");
        emit Unstaked(msg.sender, amount, newStake);
    }

    /// @notice Acuña las recompensas acumuladas en REC.
    function claim() external whenNotPaused nonReentrant returns (uint256 amount) {
        Position storage p = _accrue(msg.sender);
        amount = p.pending;
        if (amount == 0) revert NothingToClaim();
        p.pending = 0;
        token.mint(msg.sender, token.REC(), amount);
        emit Claimed(msg.sender, amount);
    }

    // ------------------------------------------------------------------ parámetros

    function setAprBps(uint16 newAprBps) external onlyRole(PARAMETERS_ROLE) {
        if (newAprBps > MAX_APR_BPS) revert AprTooHigh(newAprBps);
        _updateIndex(); // lo acumulado hasta ahora se queda con la tasa anterior
        aprBps = newAprBps;
        emit AprUpdated(newAprBps);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ vistas

    function stakeOf(address account) external view returns (uint256) {
        return _positions[account].staked;
    }

    /// @notice REC reclamable ahora mismo.
    function pendingRewards(address account) external view returns (uint256) {
        Position storage p = _positions[account];
        return p.pending + (uint256(p.staked) * (_currentIndex() - p.indexPaid)) / PRECISION;
    }

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice TKN en stake de `account` al final del instante `timepoint` (debe ser pasado).
    function getPastStake(address account, uint256 timepoint) external view returns (uint256) {
        _requirePast(timepoint);
        return _stakeHistory[account].upperLookupRecent(uint48(timepoint));
    }

    function getPastTotalStaked(uint256 timepoint) external view returns (uint256) {
        _requirePast(timepoint);
        return _totalHistory.upperLookupRecent(uint48(timepoint));
    }

    // ------------------------------------------------------------------ internos

    function _requirePast(uint256 timepoint) private view {
        if (timepoint >= clock()) revert FutureLookup(timepoint);
    }

    function _currentIndex() private view returns (uint256) {
        return
            rewardIndex + ((block.timestamp - indexUpdatedAt) * uint256(aprBps) * PRECISION) / (10_000 * YEAR);
    }

    function _updateIndex() private {
        rewardIndex = _currentIndex();
        indexUpdatedAt = uint48(block.timestamp);
    }

    function _accrue(address account) private returns (Position storage p) {
        _updateIndex();
        p = _positions[account];
        p.pending += uint128((uint256(p.staked) * (rewardIndex - p.indexPaid)) / PRECISION);
        p.indexPaid = rewardIndex;
    }

    function _setStake(address account, Position storage p, uint256 newStake, uint256 newTotal) private {
        p.staked = uint128(newStake);
        totalStaked = newTotal;
        _stakeHistory[account].push(clock(), uint208(newStake));
        _totalHistory.push(clock(), uint208(newTotal));
    }

    /// @dev Sólo se acepta TKN que este mismo contrato trae vía `stake()`.
    function onERC1155Received(address operator, address, uint256 id, uint256, bytes memory)
        public
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(token) || operator != address(this) || id != token.TKN()) {
            revert DirectTransferNotAllowed();
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
        returns (bytes4)
    {
        revert DirectTransferNotAllowed();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Holder, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
