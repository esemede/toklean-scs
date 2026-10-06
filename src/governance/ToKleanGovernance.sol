// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ToKleanStaking} from "../staking/ToKleanStaking.sol";

/// @title ToKleanGovernance
/// @notice DAO de ToKlean: propuestas votadas con el TKN en stake (snapshot), timelock, aprobación del
///         comité de compliance para propuestas con fondos/centros y pausa de emergencia de 72 h.
/// @dev Ciclo: Pending (retraso) -> Active -> Succeeded/Defeated -> Queued (timelock) -> Executed.
///      - Poder de voto = TKN en stake un segundo antes de crearse la propuesta (resiste flash-stake).
///      - Quórum = % del TKN total en stake en el snapshot; cuentan votos a favor + abstención.
///      - Las propuestas de categoría CenterAdmission y FundAllocation necesitan `approveCompliance` del
///        COMPLIANCE_ROLE antes de ejecutarse (Ley REP, D.S. 148/2003, RETC).
///      - GUARDIAN_ROLE (multisig 5-de-7): puede cancelar propuestas y activar una pausa de 72 h que bloquea
///        votar, poner en cola y ejecutar. Hay una espera de 7 días tras cada pausa (no puede congelar la DAO).
///      - Los parámetros sólo cambian mediante una propuesta ejecutada por la propia DAO.
///      - Para que la DAO ejecute acciones sobre otros contratos (p. ej. `ToKleanStaking.setAprBps`), debe
///        tener el rol correspondiente en ellos.
contract ToKleanGovernance is AccessControl {
    using Address for address;

    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant PAUSE_DURATION = 72 hours;
    uint256 public constant PAUSE_COOLDOWN = 7 days;
    uint256 public constant GRACE_PERIOD = 14 days;
    uint256 public constant MAX_TITLE_LENGTH = 120;

    enum Category {
        CenterAdmission,
        ProtocolChange,
        FundAllocation,
        Other
    }

    enum State {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
        Executed,
        Canceled,
        Expired
    }

    enum Support {
        Against,
        For,
        Abstain
    }

    struct Proposal {
        address proposer;
        Category category;
        bool executed;
        bool canceled;
        bool complianceApproved;
        uint48 snapshot;
        uint48 voteStart;
        uint48 voteEnd;
        uint48 eta;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 quorum;
        address target;
        bytes data;
        bytes32 descriptionHash;
        string title;
        string descriptionURI;
    }

    struct Params {
        uint48 votingDelay;
        uint48 votingPeriod;
        uint48 timelockDelay;
        uint16 quorumBps;
        uint256 proposalThreshold;
    }

    ToKleanStaking public immutable staking;
    Params public params;
    uint256 public proposalCount;
    uint48 public pausedUntil;
    uint48 public lastPauseEnd;

    mapping(uint256 id => Proposal) private _proposals;
    mapping(uint256 id => mapping(address voter => bool)) public hasVoted;

    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        Category category,
        string title,
        string descriptionURI,
        uint48 voteStart,
        uint48 voteEnd
    );
    event VoteCast(uint256 indexed id, address indexed voter, Support support, uint256 weight);
    event ProposalQueued(uint256 indexed id, uint48 eta);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCanceled(uint256 indexed id, address indexed by);
    event ComplianceApproved(uint256 indexed id, address indexed by);
    event EmergencyPause(address indexed by, uint48 until);
    event ParamsUpdated(Params params);

    error ZeroAddress();
    error NotGovernance();
    error InvalidParams();
    error PausedByGuardian(uint48 until);
    error PauseCooldown(uint48 availableAt);
    error BelowThreshold(uint256 stake, uint256 required);
    error InvalidTitle();
    error InvalidProposal(uint256 id);
    error WrongState(uint256 id, State current);
    error AlreadyVoted(uint256 id, address voter);
    error NoVotingPower(uint256 id, address voter);
    error ComplianceRequired(uint256 id);
    error TimelockNotElapsed(uint256 id, uint48 eta);
    error NotProposerOrGuardian(address caller);

    modifier onlyGovernance() {
        if (msg.sender != address(this)) revert NotGovernance();
        _;
    }

    modifier notPaused() {
        if (block.timestamp < pausedUntil) revert PausedByGuardian(pausedUntil);
        _;
    }

    constructor(ToKleanStaking staking_, address admin, Params memory initial) {
        if (address(staking_) == address(0) || admin == address(0)) revert ZeroAddress();
        staking = staking_;
        _validate(initial);
        params = initial;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        emit ParamsUpdated(initial);
    }

    // ------------------------------------------------------------------ propuestas

    /// @param target Contrato a invocar si la propuesta se aprueba (address(0) = propuesta de señal, sin ejecución).
    /// @param data Calldata de la invocación (valor 0).
    function propose(
        string calldata title,
        string calldata descriptionURI,
        bytes32 descriptionHash,
        Category category,
        address target,
        bytes calldata data
    ) external notPaused returns (uint256 id) {
        uint256 len = bytes(title).length;
        if (len == 0 || len > MAX_TITLE_LENGTH) revert InvalidTitle();
        uint48 snapshot = uint48(block.timestamp) - 1;
        uint256 stake = staking.getPastStake(msg.sender, snapshot);
        if (stake < params.proposalThreshold) revert BelowThreshold(stake, params.proposalThreshold);

        id = ++proposalCount;
        Proposal storage p = _proposals[id];
        p.proposer = msg.sender;
        p.category = category;
        p.snapshot = snapshot;
        p.voteStart = uint48(block.timestamp) + params.votingDelay;
        p.voteEnd = p.voteStart + params.votingPeriod;
        p.quorum = (staking.getPastTotalStaked(snapshot) * params.quorumBps) / 10_000;
        p.target = target;
        p.data = data;
        p.descriptionHash = descriptionHash;
        p.title = title;
        p.descriptionURI = descriptionURI;

        emit ProposalCreated(id, msg.sender, category, title, descriptionURI, p.voteStart, p.voteEnd);
    }

    function castVote(uint256 id, Support support) external notPaused returns (uint256 weight) {
        Proposal storage p = _get(id);
        State s = _state(p);
        if (s != State.Active) revert WrongState(id, s);
        if (hasVoted[id][msg.sender]) revert AlreadyVoted(id, msg.sender);
        weight = staking.getPastStake(msg.sender, p.snapshot);
        if (weight == 0) revert NoVotingPower(id, msg.sender);

        hasVoted[id][msg.sender] = true;
        if (support == Support.For) p.forVotes += weight;
        else if (support == Support.Against) p.againstVotes += weight;
        else p.abstainVotes += weight;
        emit VoteCast(id, msg.sender, support, weight);
    }

    /// @notice El comité de compliance valida la propuesta (obligatorio para centros y fondos).
    function approveCompliance(uint256 id) external onlyRole(COMPLIANCE_ROLE) {
        Proposal storage p = _get(id);
        State s = _state(p);
        if (s != State.Succeeded && s != State.Queued) revert WrongState(id, s);
        p.complianceApproved = true;
        emit ComplianceApproved(id, msg.sender);
    }

    function queue(uint256 id) external notPaused {
        Proposal storage p = _get(id);
        State s = _state(p);
        if (s != State.Succeeded) revert WrongState(id, s);
        p.eta = uint48(block.timestamp) + params.timelockDelay;
        emit ProposalQueued(id, p.eta);
    }

    function execute(uint256 id) external notPaused {
        Proposal storage p = _get(id);
        State s = _state(p);
        if (s != State.Queued) revert WrongState(id, s);
        if (block.timestamp < p.eta) revert TimelockNotElapsed(id, p.eta);
        if (_requiresCompliance(p.category) && !p.complianceApproved) revert ComplianceRequired(id);

        p.executed = true;
        if (p.target != address(0)) p.target.functionCall(p.data);
        emit ProposalExecuted(id);
    }

    /// @notice Cancela el proponente (antes de ejecutarse) o un guardián.
    function cancel(uint256 id) external {
        Proposal storage p = _get(id);
        if (msg.sender != p.proposer && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert NotProposerOrGuardian(msg.sender);
        }
        State s = _state(p);
        if (s == State.Executed || s == State.Canceled) revert WrongState(id, s);
        p.canceled = true;
        emit ProposalCanceled(id, msg.sender);
    }

    // ------------------------------------------------------------------ emergencia

    function emergencyPause() external onlyRole(GUARDIAN_ROLE) {
        uint48 availableAt = lastPauseEnd + uint48(PAUSE_COOLDOWN);
        if (lastPauseEnd != 0 && block.timestamp < availableAt) revert PauseCooldown(availableAt);
        pausedUntil = uint48(block.timestamp + PAUSE_DURATION);
        lastPauseEnd = pausedUntil;
        emit EmergencyPause(msg.sender, pausedUntil);
    }

    // ------------------------------------------------------------------ parámetros (sólo vía DAO)

    function setParams(Params calldata newParams) external onlyGovernance {
        _validate(newParams);
        params = newParams;
        emit ParamsUpdated(newParams);
    }

    // ------------------------------------------------------------------ vistas

    function state(uint256 id) external view returns (State) {
        return _state(_get(id));
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _get(id);
    }

    function requiresCompliance(Category category) external pure returns (bool) {
        return _requiresCompliance(category);
    }

    // ------------------------------------------------------------------ internos

    function _get(uint256 id) private view returns (Proposal storage p) {
        if (id == 0 || id > proposalCount) revert InvalidProposal(id);
        p = _proposals[id];
    }

    function _requiresCompliance(Category c) private pure returns (bool) {
        return c == Category.CenterAdmission || c == Category.FundAllocation;
    }

    function _state(Proposal storage p) private view returns (State) {
        if (p.canceled) return State.Canceled;
        if (p.executed) return State.Executed;
        if (block.timestamp < p.voteStart) return State.Pending;
        if (block.timestamp <= p.voteEnd) return State.Active;
        if (p.forVotes + p.abstainVotes < p.quorum || p.forVotes <= p.againstVotes) return State.Defeated;
        if (p.eta == 0) return State.Succeeded;
        if (block.timestamp > p.eta + GRACE_PERIOD) return State.Expired;
        return State.Queued;
    }

    function _validate(Params memory x) private pure {
        if (
            x.votingPeriod < 1 hours || x.votingPeriod > 30 days || x.votingDelay > 14 days
                || x.timelockDelay > 30 days || x.quorumBps == 0 || x.quorumBps > 10_000
                || x.proposalThreshold == 0
        ) revert InvalidParams();
    }
}
