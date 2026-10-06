// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {EconomyBase} from "./EconomyBase.t.sol";
import {ToKleanToken} from "../src/token/ToKleanToken.sol";
import {TokenFaucet} from "../src/token/TokenFaucet.sol";

contract ToKleanTokenTest is EconomyBase {
    function test_idsAndMetadata() public view {
        assertEq(TKN, 1);
        assertEq(REC, 2);
        assertEq(POR, 3);
        assertEq(token.name(), "ToKlean");
        assertEq(token.maxSupply(TKN), TKN_CAP);
        assertEq(token.maxSupply(REC), 0);
    }

    function test_uriIsOnChainJsonPerId() public view {
        string memory expected = string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    '{"name":"ToKlean Reward (REC)","symbol":"REC","decimals":18,"description":"Recompensa liquida por reciclar y por staking. Se quema en el juego."}'
                )
            )
        );
        assertEq(token.uri(REC), expected);
        assertTrue(keccak256(bytes(token.uri(TKN))) != keccak256(bytes(token.uri(POR))));
    }

    function test_uriRejectsUnknownIds() public {
        vm.expectRevert(abi.encodeWithSelector(ToKleanToken.InvalidTokenId.selector, 0));
        token.uri(0);
        vm.expectRevert(abi.encodeWithSelector(ToKleanToken.InvalidTokenId.selector, 4));
        token.uri(4);
    }

    function test_onlyMinterCanMint() public {
        bytes32 role = token.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        token.mint(alice, TKN, 1);
    }

    function test_cannotMintUnknownId() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ToKleanToken.InvalidTokenId.selector, 9));
        token.mint(alice, 9, 1);
    }

    function test_capIsEnforcedOnTknButNotRec() public {
        vm.startPrank(admin);
        token.mint(alice, TKN, TKN_CAP);
        vm.expectRevert(abi.encodeWithSelector(ToKleanToken.CapExceeded.selector, TKN, TKN_CAP + 1, TKN_CAP));
        token.mint(alice, TKN, 1);
        token.mint(alice, REC, type(uint128).max); // REC sin tope
        vm.stopPrank();
        assertEq(token.totalSupply(REC), type(uint128).max);
    }

    function test_capCountsRepeatedIdsInOneBatch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = TKN;
        ids[1] = TKN;
        amounts[0] = TKN_CAP;
        amounts[1] = 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ToKleanToken.CapExceeded.selector, TKN, TKN_CAP + 1, TKN_CAP));
        token.mintBatch(alice, ids, amounts);
    }

    function test_burnReducesSupplyAndFreesCapacity() public {
        vm.prank(admin);
        token.mint(alice, TKN, TKN_CAP);
        vm.prank(alice);
        token.burn(alice, TKN, 10 ether);
        assertEq(token.totalSupply(TKN), TKN_CAP - 10 ether);
        vm.prank(admin);
        token.mint(bob, TKN, 10 ether);
    }

    function test_setMaxSupplyCannotGoBelowSupply() public {
        vm.startPrank(admin);
        token.mint(alice, REC, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanToken.CapBelowSupply.selector, REC, 50 ether, 100 ether)
        );
        token.setMaxSupply(REC, 50 ether);
        token.setMaxSupply(REC, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(ToKleanToken.CapExceeded.selector, REC, 101 ether, 100 ether));
        token.mint(alice, REC, 1 ether);
        vm.stopPrank();
    }

    function test_pauseBlocksTransfersMintAndBurn() public {
        _fund(alice, 10 ether);
        vm.prank(admin);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.safeTransferFrom(alice, bob, TKN, 1 ether, "");
        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.mint(alice, TKN, 1);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.burn(alice, TKN, 1);

        vm.prank(admin);
        token.unpause();
        vm.prank(alice);
        token.safeTransferFrom(alice, bob, TKN, 1 ether, "");
        assertEq(token.balanceOf(bob, TKN), 1 ether);
    }

    function test_onlyPauserCanPause() public {
        bytes32 role = token.PAUSER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        token.pause();
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(ToKleanToken.ZeroAddress.selector);
        new ToKleanToken(address(0), 1);
    }

    // ----------------------------------------------------------------- faucet

    function test_faucetGives50TknOncePerDay() public {
        vm.prank(alice);
        faucet.claim();
        assertEq(token.balanceOf(alice, TKN), 50 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TokenFaucet.CooldownActive.selector, vm.getBlockTimestamp() + 1 days)
        );
        faucet.claim();
        assertEq(faucet.secondsUntilClaim(alice), 1 days);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(faucet.secondsUntilClaim(alice), 0);
        vm.prank(alice);
        faucet.claim();
        assertEq(token.balanceOf(alice, TKN), 100 ether);
    }

    function test_faucetCanBeDisabledAndReconfiguredByAdminOnly() public {
        bytes32 role = faucet.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        faucet.configure(1, 1, true);

        vm.prank(admin);
        faucet.configure(10 ether, 1 hours, false);
        vm.prank(alice);
        vm.expectRevert(TokenFaucet.FaucetDisabled.selector);
        faucet.claim();
    }

    function test_faucetRefusesMainnets() public {
        uint256[7] memory chains = [uint256(1), 137, 10, 42161, 8453, 56, 43114];
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            vm.expectRevert(abi.encodeWithSelector(TokenFaucet.MainnetNotAllowed.selector, chains[i]));
            new TokenFaucet(token, admin);
        }
    }

    function test_faucetRespectsTknCap() public {
        vm.prank(admin);
        token.mint(bob, TKN, TKN_CAP - 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ToKleanToken.CapExceeded.selector, TKN, TKN_CAP + 40 ether, TKN_CAP)
        );
        faucet.claim();
    }
}
