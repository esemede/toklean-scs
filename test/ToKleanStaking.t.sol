// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EconomyBase} from "./EconomyBase.t.sol";
import {ToKleanStaking} from "../src/staking/ToKleanStaking.sol";

contract ToKleanStakingTest is EconomyBase {
    uint256 constant YEAR = 365 days;

    function test_stakeMovesTknIntoTheContract() public {
        _stake(alice, 100 ether);
        assertEq(token.balanceOf(alice, TKN), 0);
        assertEq(token.balanceOf(address(staking), TKN), 100 ether);
        assertEq(staking.stakeOf(alice), 100 ether);
        assertEq(staking.totalStaked(), 100 ether);
    }

    function test_stakeRequiresApprovalAndBalance() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(); // ERC1155MissingApprovalForAll
        staking.stake(10 ether);

        vm.startPrank(alice);
        token.setApprovalForAll(address(staking), true);
        vm.expectRevert(); // ERC1155InsufficientBalance
        staking.stake(11 ether);
        vm.stopPrank();
    }

    function test_zeroAmountsRevert() public {
        vm.startPrank(alice);
        vm.expectRevert(ToKleanStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(ToKleanStaking.ZeroAmount.selector);
        staking.unstake(0);
        vm.stopPrank();
    }

    function test_rewardsAccrueLinearlyAtApr() public {
        _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR);
        // 12,5 % de 100 TKN en un año = 12,5 REC
        assertEq(staking.pendingRewards(alice), 12.5 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR);
        assertEq(staking.pendingRewards(alice), 25 ether);
    }

    function test_claimMintsRecAndResetsPending() public {
        _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR);
        vm.prank(alice);
        uint256 claimed = staking.claim();
        assertEq(claimed, 12.5 ether);
        assertEq(token.balanceOf(alice, REC), 12.5 ether);
        assertEq(staking.pendingRewards(alice), 0);

        vm.prank(alice);
        vm.expectRevert(ToKleanStaking.NothingToClaim.selector);
        staking.claim();
    }

    function test_unstakeReturnsTknAndKeepsRewards() public {
        _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR);
        vm.prank(alice);
        staking.unstake(40 ether);
        assertEq(token.balanceOf(alice, TKN), 40 ether);
        assertEq(staking.stakeOf(alice), 60 ether);
        assertEq(staking.pendingRewards(alice), 12.5 ether); // lo ganado no se pierde
        vm.warp(vm.getBlockTimestamp() + YEAR);
        assertEq(staking.pendingRewards(alice), 12.5 ether + 7.5 ether); // 60 TKN * 12,5 %
    }

    function test_cannotUnstakeMoreThanStaked() public {
        _stake(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ToKleanStaking.InsufficientStake.selector, 11 ether, 10 ether));
        staking.unstake(11 ether);
    }

    function test_aprChangeIsNotRetroactive() public {
        _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR / 2); // 6,25 REC al 12,5 %
        vm.prank(admin);
        staking.setAprBps(2500); // 25 %
        assertEq(staking.pendingRewards(alice), 6.25 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR / 2); // + 12,5 REC al 25 %
        assertEq(staking.pendingRewards(alice), 6.25 ether + 12.5 ether);
    }

    function test_aprIsCappedAndRoleGated() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ToKleanStaking.AprTooHigh.selector, uint16(5001)));
        staking.setAprBps(5001);

        bytes32 role = staking.PARAMETERS_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        staking.setAprBps(100);
    }

    function test_twoStakersAccrueIndependently() public {
        _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR / 2);
        _stake(bob, 100 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR / 2);
        assertEq(staking.pendingRewards(alice), 12.5 ether);
        assertEq(staking.pendingRewards(bob), 6.25 ether);
    }

    function test_pauseBlocksStakeAndClaimButNotUnstake() public {
        _stake(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + YEAR);
        vm.prank(admin);
        staking.pause();

        _fund(bob, 1 ether);
        vm.startPrank(bob);
        token.setApprovalForAll(address(staking), true);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.stake(1 ether);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staking.claim();
        staking.unstake(100 ether); // los fondos nunca quedan atrapados
        vm.stopPrank();
        assertEq(token.balanceOf(alice, TKN), 100 ether);
    }

    function test_rejectsDirectTransfersOfAnyToken() public {
        _fund(alice, 10 ether);
        vm.prank(admin);
        token.mint(alice, REC, 10 ether);

        vm.startPrank(alice);
        vm.expectRevert(ToKleanStaking.DirectTransferNotAllowed.selector);
        token.safeTransferFrom(alice, address(staking), TKN, 1 ether, "");
        vm.expectRevert(ToKleanStaking.DirectTransferNotAllowed.selector);
        token.safeTransferFrom(alice, address(staking), REC, 1 ether, "");
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = TKN;
        amounts[0] = 1 ether;
        vm.expectRevert(ToKleanStaking.DirectTransferNotAllowed.selector);
        token.safeBatchTransferFrom(alice, address(staking), ids, amounts, "");
        vm.stopPrank();
    }

    function test_historyIsQueryableOnlyForThePast() public {
        _stake(alice, 100 ether);
        uint256 t0 = vm.getBlockTimestamp();
        vm.expectRevert(abi.encodeWithSelector(ToKleanStaking.FutureLookup.selector, t0));
        staking.getPastStake(alice, t0);

        vm.warp(t0 + 10);
        _stake(alice, 50 ether);
        vm.warp(t0 + 20);
        assertEq(staking.getPastStake(alice, t0), 100 ether);
        assertEq(staking.getPastStake(alice, t0 + 9), 100 ether);
        assertEq(staking.getPastStake(alice, t0 + 10), 150 ether);
        assertEq(staking.getPastStake(alice, t0 - 1), 0);
        assertEq(staking.getPastTotalStaked(t0 + 10), 150 ether);

        vm.prank(alice);
        staking.unstake(150 ether);
        vm.warp(t0 + 30);
        assertEq(staking.getPastStake(alice, t0 + 25), 0);
        assertEq(staking.getPastStake(alice, t0 + 15), 150 ether);
    }

    function test_constructorValidation() public {
        vm.expectRevert(ToKleanStaking.ZeroAddress.selector);
        new ToKleanStaking(token, address(0), 100);
        vm.expectRevert(abi.encodeWithSelector(ToKleanStaking.AprTooHigh.selector, uint16(6000)));
        new ToKleanStaking(token, admin, 6000);
    }

    // ----------------------------------------------------------------- fuzz

    function testFuzz_rewardsMatchFormula(uint96 amount, uint32 elapsed) public {
        amount = uint96(bound(amount, 1 ether, 100_000_000 ether));
        elapsed = uint32(bound(elapsed, 1, 5 * YEAR));
        _stake(alice, amount);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 expected = (uint256(amount) * APR * elapsed) / (10_000 * YEAR);
        // el índice trunca a 1e18: error máximo de 1 wei por TKN-segundo -> tolerancia de unos pocos wei
        assertApproxEqAbs(staking.pendingRewards(alice), expected, amount / 1e18 + 1);
    }

    function testFuzz_stakeThenUnstakeConservesTkn(uint96 amount, uint96 part) public {
        amount = uint96(bound(amount, 2, 1_000_000_000 ether));
        part = uint96(bound(part, 1, amount));
        _stake(alice, amount);
        vm.prank(alice);
        staking.unstake(part);
        assertEq(token.balanceOf(alice, TKN) + staking.stakeOf(alice), amount);
        assertEq(token.balanceOf(address(staking), TKN), staking.totalStaked());
    }
}
