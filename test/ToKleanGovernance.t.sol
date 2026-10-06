// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {EconomyBase} from "./EconomyBase.t.sol";
import {ToKleanGovernance} from "../src/governance/ToKleanGovernance.sol";
import {ToKleanStaking} from "../src/staking/ToKleanStaking.sol";

contract ToKleanGovernanceTest is EconomyBase {
    ToKleanGovernance.Category constant CENTER = ToKleanGovernance.Category.CenterAdmission;
    ToKleanGovernance.Category constant PROTOCOL = ToKleanGovernance.Category.ProtocolChange;
    ToKleanGovernance.Category constant FUNDS = ToKleanGovernance.Category.FundAllocation;
    ToKleanGovernance.Category constant OTHER = ToKleanGovernance.Category.Other;
    ToKleanGovernance.Support constant FOR = ToKleanGovernance.Support.For;
    ToKleanGovernance.Support constant AGAINST = ToKleanGovernance.Support.Against;
    ToKleanGovernance.Support constant ABSTAIN = ToKleanGovernance.Support.Abstain;

    function setUp() public override {
        super.setUp();
        // alice 600, bob 300, carol 100 -> total 1000 TKN en stake (quórum 4 % = 40)
        _stake(alice, 600 ether);
        _stake(bob, 300 ether);
        _stake(carol, 100 ether);
        skip(1 hours); // los stakes quedan en el pasado
    }

    function _propose(address who, ToKleanGovernance.Category cat, address target, bytes memory data)
        internal
        returns (uint256)
    {
        vm.prank(who);
        return gov.propose("Titulo", "ipfs://bafydesc", keccak256("desc"), cat, target, data);
    }

    function _signal(ToKleanGovernance.Category cat) internal returns (uint256) {
        return _propose(alice, cat, address(0), "");
    }

    function _toActive() internal {
        skip(1 days + 1);
    }

    function _toEnd() internal {
        skip(5 days + 1);
    }

    function _state(uint256 id) internal view returns (ToKleanGovernance.State) {
        return gov.state(id);
    }

    // ----------------------------------------------------------------- crear

    function test_proposeStoresProposalAndSnapshot() public {
        uint256 t = vm.getBlockTimestamp();
        uint256 id = _signal(PROTOCOL);
        assertEq(id, 1);
        ToKleanGovernance.Proposal memory p = gov.getProposal(id);
        assertEq(p.proposer, alice);
        assertEq(p.snapshot, t - 1);
        assertEq(p.voteStart, t + 1 days);
        assertEq(p.voteEnd, t + 6 days);
        assertEq(p.quorum, 40 ether);
        assertEq(p.title, "Titulo");
        assertEq(p.descriptionURI, "ipfs://bafydesc");
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Pending));
    }

    function test_proposeNeedsThresholdOnPastStake() public {
        address dave = makeAddr("dave");
        _stake(dave, 99 ether);
        skip(1);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.BelowThreshold.selector, 99 ether, 100 ether)
        );
        gov.propose("T", "u", 0, OTHER, address(0), "");
    }

    function test_flashStakeInTheSameBlockCannotPropose() public {
        address dave = makeAddr("dave");
        _stake(dave, 1000 ether); // se apila en este mismo instante
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.BelowThreshold.selector, 0, 100 ether));
        gov.propose("T", "u", 0, OTHER, address(0), "");
    }

    function test_titleValidation() public {
        vm.startPrank(alice);
        vm.expectRevert(ToKleanGovernance.InvalidTitle.selector);
        gov.propose("", "u", 0, OTHER, address(0), "");
        bytes memory long = new bytes(121);
        for (uint256 i = 0; i < long.length; i++) {
            long[i] = "a";
        }
        vm.expectRevert(ToKleanGovernance.InvalidTitle.selector);
        gov.propose(string(long), "u", 0, OTHER, address(0), "");
        vm.stopPrank();
    }

    function test_unknownProposalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.InvalidProposal.selector, 7));
        gov.state(7);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.InvalidProposal.selector, 0));
        gov.state(0);
    }

    // ----------------------------------------------------------------- votar

    function test_cannotVoteBeforeStartOrAfterEnd() public {
        uint256 id = _signal(PROTOCOL);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.WrongState.selector, id, ToKleanGovernance.State.Pending)
        );
        gov.castVote(id, FOR);

        _toActive();
        _toEnd();
        vm.prank(alice);
        vm.expectRevert();
        gov.castVote(id, FOR);
    }

    function test_voteWeightIsTheStakeAtSnapshot() public {
        uint256 id = _signal(PROTOCOL);
        // alice se retira y bob añade stake DESPUÉS de crearse la propuesta: no cambia sus pesos
        vm.prank(alice);
        staking.unstake(600 ether);
        _stake(bob, 500 ether);
        _toActive();

        vm.prank(alice);
        assertEq(gov.castVote(id, FOR), 600 ether);
        vm.prank(bob);
        assertEq(gov.castVote(id, AGAINST), 300 ether);
        ToKleanGovernance.Proposal memory p = gov.getProposal(id);
        assertEq(p.forVotes, 600 ether);
        assertEq(p.againstVotes, 300 ether);
    }

    function test_stakeAddedAfterProposalHasNoVotingPower() public {
        uint256 id = _signal(PROTOCOL);
        address dave = makeAddr("dave");
        skip(1);
        _stake(dave, 5000 ether);
        _toActive();
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.NoVotingPower.selector, id, dave));
        gov.castVote(id, FOR);
    }

    function test_cannotVoteTwice() public {
        uint256 id = _signal(PROTOCOL);
        _toActive();
        vm.startPrank(alice);
        gov.castVote(id, FOR);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.AlreadyVoted.selector, id, alice));
        gov.castVote(id, AGAINST);
        vm.stopPrank();
    }

    function test_movingTknToAnotherAccountDoesNotDoubleVote() public {
        uint256 id = _signal(PROTOCOL);
        _toActive();
        vm.prank(carol);
        gov.castVote(id, FOR);
        // carol retira y pasa sus TKN a dave, que stakea: sin poder para esta propuesta
        vm.startPrank(carol);
        staking.unstake(100 ether);
        token.safeTransferFrom(carol, bob, TKN, 100 ether, "");
        vm.stopPrank();
        address dave = makeAddr("dave");
        _stake(dave, 100 ether);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.NoVotingPower.selector, id, dave));
        gov.castVote(id, FOR);
    }

    // ----------------------------------------------------------------- resultados

    function test_defeatedWhenQuorumNotReached() public {
        // DAO con quórum del 50 %: 500 TKN de 1000. carol sólo aporta 100 a favor y nadie más vota.
        ToKleanGovernance strict =
            new ToKleanGovernance(staking, admin, _params(1 days, 5 days, 2 days, 5000, 100 ether));
        vm.prank(alice);
        uint256 id = strict.propose("T", "u", 0, OTHER, address(0), "");
        skip(1 days + 1);
        vm.prank(carol);
        strict.castVote(id, FOR);
        skip(5 days + 1);
        assertEq(uint8(strict.state(id)), uint8(ToKleanGovernance.State.Defeated));
        assertEq(strict.getProposal(id).quorum, 500 ether);

        // la misma votación sí pasa con quórum 4 %
        uint256 ok = _signal(PROTOCOL);
        skip(1 days + 1);
        vm.prank(carol);
        gov.castVote(ok, FOR);
        skip(5 days + 1);
        assertEq(uint8(_state(ok)), uint8(ToKleanGovernance.State.Succeeded));
    }

    function test_defeatedWhenAgainstWinsOrTies() public {
        uint256 id = _signal(PROTOCOL);
        _toActive();
        vm.prank(alice);
        gov.castVote(id, AGAINST);
        vm.prank(bob);
        gov.castVote(id, FOR);
        _toEnd();
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Defeated));
    }

    function test_abstainCountsTowardQuorumButNotTowardsApproval() public {
        uint256 id = _signal(PROTOCOL);
        _toActive();
        vm.prank(alice);
        gov.castVote(id, ABSTAIN); // 600 abstenciones: quórum ok, pero for (0) <= against (0)
        _toEnd();
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Defeated));
    }

    function test_succeedsWithQuorumAndMajority() public {
        uint256 id = _signal(PROTOCOL);
        _toActive();
        vm.prank(carol);
        gov.castVote(id, FOR); // 100 >= quórum 40
        _toEnd();
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Succeeded));
    }

    // ----------------------------------------------------------------- ejecución

    function _approve(uint256 id) internal {
        _toActive();
        vm.prank(alice);
        gov.castVote(id, FOR);
        _toEnd();
    }

    function test_fullLifecycleExecutesTheCallThroughTheDao() public {
        bytes memory data = abi.encodeCall(ToKleanStaking.setAprBps, (2000));
        uint256 id = _propose(alice, PROTOCOL, address(staking), data);
        _approve(id);

        gov.queue(id);
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Queued));
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.TimelockNotElapsed.selector, id, gov.getProposal(id).eta)
        );
        gov.execute(id);

        skip(2 days);
        gov.execute(id);
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Executed));
        assertEq(staking.aprBps(), 2000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanGovernance.WrongState.selector, id, ToKleanGovernance.State.Executed
            )
        );
        gov.execute(id);
    }

    function test_signalProposalExecutesWithoutACall() public {
        uint256 id = _signal(OTHER);
        _approve(id);
        gov.queue(id);
        skip(2 days);
        gov.execute(id);
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Executed));
    }

    function test_cannotQueueOrExecuteOutOfOrder() public {
        uint256 id = _signal(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.WrongState.selector, id, ToKleanGovernance.State.Pending)
        );
        gov.queue(id);
        _approve(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanGovernance.WrongState.selector, id, ToKleanGovernance.State.Succeeded
            )
        );
        gov.execute(id);
        gov.queue(id);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.WrongState.selector, id, ToKleanGovernance.State.Queued)
        );
        gov.queue(id);
    }

    function test_queuedProposalExpiresAfterGracePeriod() public {
        uint256 id = _signal(OTHER);
        _approve(id);
        gov.queue(id);
        skip(2 days + 14 days + 1);
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Expired));
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.WrongState.selector, id, ToKleanGovernance.State.Expired)
        );
        gov.execute(id);
    }

    function test_failingTargetCallRevertsAndKeepsTheProposalQueued() public {
        // setAprBps(6000) supera el máximo del staking
        bytes memory data = abi.encodeCall(ToKleanStaking.setAprBps, (6000));
        uint256 id = _propose(alice, PROTOCOL, address(staking), data);
        _approve(id);
        gov.queue(id);
        skip(2 days);
        vm.expectRevert(abi.encodeWithSelector(ToKleanStaking.AprTooHigh.selector, uint16(6000)));
        gov.execute(id);
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Queued));
    }

    // ----------------------------------------------------------------- compliance

    function test_fundAndCenterProposalsNeedComplianceApproval() public {
        assertTrue(gov.requiresCompliance(FUNDS));
        assertTrue(gov.requiresCompliance(CENTER));
        assertFalse(gov.requiresCompliance(PROTOCOL));
        assertFalse(gov.requiresCompliance(OTHER));

        uint256 id = _signal(FUNDS);
        _approve(id);
        gov.queue(id);
        skip(2 days);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.ComplianceRequired.selector, id));
        gov.execute(id);

        vm.prank(compliance);
        gov.approveCompliance(id);
        gov.execute(id);
        assertEq(uint8(_state(id)), uint8(ToKleanGovernance.State.Executed));
    }

    function test_complianceCanApproveOnceTheVoteSucceeded() public {
        uint256 id = _signal(CENTER);
        vm.prank(compliance);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.WrongState.selector, id, ToKleanGovernance.State.Pending)
        );
        gov.approveCompliance(id);

        _approve(id);
        vm.prank(compliance);
        gov.approveCompliance(id); // en Succeeded
    }

    function test_onlyComplianceRoleCanApprove() public {
        uint256 id = _signal(FUNDS);
        _approve(id);
        bytes32 role = gov.COMPLIANCE_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        gov.approveCompliance(id);
    }

    // ----------------------------------------------------------------- cancelar

    function test_proposerOrGuardianCanCancelOthersCannot() public {
        uint256 a = _signal(OTHER);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.NotProposerOrGuardian.selector, bob));
        gov.cancel(a);

        vm.prank(alice);
        gov.cancel(a);
        assertEq(uint8(_state(a)), uint8(ToKleanGovernance.State.Canceled));

        uint256 b = _signal(OTHER);
        vm.prank(guardian);
        gov.cancel(b);
        assertEq(uint8(_state(b)), uint8(ToKleanGovernance.State.Canceled));

        _toActive();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.WrongState.selector, b, ToKleanGovernance.State.Canceled)
        );
        gov.cancel(b);
    }

    function test_cannotCancelAnExecutedProposal() public {
        uint256 id = _signal(OTHER);
        _approve(id);
        gov.queue(id);
        skip(2 days);
        gov.execute(id);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanGovernance.WrongState.selector, id, ToKleanGovernance.State.Executed
            )
        );
        gov.cancel(id);
    }

    // ----------------------------------------------------------------- guardián

    function test_guardianPauseBlocksGovernanceFor72hAndThenExpires() public {
        uint256 id = _signal(OTHER);
        _toActive();
        vm.prank(guardian);
        gov.emergencyPause();
        uint48 until = gov.pausedUntil();
        assertEq(until, vm.getBlockTimestamp() + 72 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.PausedByGuardian.selector, until));
        gov.castVote(id, FOR);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ToKleanGovernance.PausedByGuardian.selector, until));
        gov.propose("T", "u", 0, OTHER, address(0), "");

        skip(72 hours);
        vm.prank(alice);
        gov.castVote(id, FOR); // la pausa expira sola
    }

    function test_pauseBlocksQueueAndExecute() public {
        uint256 id = _signal(OTHER);
        _approve(id);
        vm.prank(guardian);
        gov.emergencyPause();
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanGovernance.PausedByGuardian.selector, gov.pausedUntil())
        );
        gov.queue(id);
    }

    function test_guardianCannotRepauseDuringCooldown() public {
        vm.prank(guardian);
        gov.emergencyPause();
        skip(72 hours);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                ToKleanGovernance.PauseCooldown.selector, uint48(vm.getBlockTimestamp() + 7 days)
            )
        );
        gov.emergencyPause();
        skip(7 days);
        vm.prank(guardian);
        gov.emergencyPause();
    }

    function test_onlyGuardianCanPause() public {
        bytes32 role = gov.GUARDIAN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        gov.emergencyPause();
    }

    function test_cancelStillWorksDuringPause() public {
        uint256 id = _signal(OTHER);
        vm.startPrank(guardian);
        gov.emergencyPause();
        gov.cancel(id);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- parámetros

    function _params(uint48 delay, uint48 period, uint48 timelock, uint16 quorum, uint256 threshold)
        internal
        pure
        returns (ToKleanGovernance.Params memory)
    {
        return ToKleanGovernance.Params(delay, period, timelock, quorum, threshold);
    }

    function test_paramsCannotBeChangedDirectly() public {
        vm.prank(admin);
        vm.expectRevert(ToKleanGovernance.NotGovernance.selector);
        gov.setParams(_params(0, 1 days, 0, 100, 1 ether));
    }

    function test_daoCanChangeItsOwnParameters() public {
        bytes memory data =
            abi.encodeCall(ToKleanGovernance.setParams, (_params(0, 2 days, 1 days, 1000, 50 ether)));
        uint256 id = _propose(alice, PROTOCOL, address(gov), data);
        _approve(id);
        gov.queue(id);
        skip(2 days);
        gov.execute(id);

        (uint48 delay, uint48 period, uint48 timelock, uint16 quorum, uint256 threshold) = gov.params();
        assertEq(delay, 0);
        assertEq(period, 2 days);
        assertEq(timelock, 1 days);
        assertEq(quorum, 1000);
        assertEq(threshold, 50 ether);
    }

    function test_invalidParamsAreRejected() public {
        ToKleanGovernance.Params[5] memory bad = [
            _params(0, 30 minutes, 0, 400, 1 ether), // período < 1 h
            _params(0, 31 days, 0, 400, 1 ether), // período > 30 días
            _params(0, 1 days, 0, 0, 1 ether), // quórum 0
            _params(0, 1 days, 0, 10_001, 1 ether), // quórum > 100 %
            _params(0, 1 days, 0, 400, 0) // umbral 0
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(ToKleanGovernance.InvalidParams.selector);
            new ToKleanGovernance(staking, admin, bad[i]);
        }
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ToKleanGovernance.ZeroAddress.selector);
        new ToKleanGovernance(staking, address(0), _params(0, 1 days, 0, 400, 1 ether));
    }
}
