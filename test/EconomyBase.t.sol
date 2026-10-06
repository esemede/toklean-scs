// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ToKleanToken} from "../src/token/ToKleanToken.sol";
import {TokenFaucet} from "../src/token/TokenFaucet.sol";
import {ToKleanStaking} from "../src/staking/ToKleanStaking.sol";
import {ToKleanGovernance} from "../src/governance/ToKleanGovernance.sol";

abstract contract EconomyBase is Test {
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address compliance = makeAddr("compliance");
    address guardian = makeAddr("guardian");

    uint256 constant TKN_CAP = 1_000_000_000 ether;
    uint16 constant APR = 1250; // 12,5 %

    ToKleanToken token;
    ToKleanStaking staking;
    ToKleanGovernance gov;
    TokenFaucet faucet;

    uint256 TKN;
    uint256 REC;
    uint256 POR;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        token = new ToKleanToken(admin, TKN_CAP);
        TKN = token.TKN();
        REC = token.REC();
        POR = token.POR();
        staking = new ToKleanStaking(token, admin, APR);
        faucet = new TokenFaucet(token, admin);
        gov = new ToKleanGovernance(
            staking,
            admin,
            ToKleanGovernance.Params({
                votingDelay: 1 days,
                votingPeriod: 5 days,
                timelockDelay: 2 days,
                quorumBps: 400,
                proposalThreshold: 100 ether
            })
        );

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(staking));
        token.grantRole(token.MINTER_ROLE(), address(faucet));
        token.grantRole(token.MINTER_ROLE(), admin);
        staking.grantRole(staking.PARAMETERS_ROLE(), address(gov));
        gov.grantRole(gov.COMPLIANCE_ROLE(), compliance);
        gov.grantRole(gov.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(admin);
        token.mint(who, TKN, amount);
    }

    function _stake(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.startPrank(who);
        token.setApprovalForAll(address(staking), true);
        staking.stake(amount);
        vm.stopPrank();
    }
}
