// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {BaseTest} from "./Base.t.sol";
import {CleanupActionNFT} from "../src/CleanupActionNFT.sol";
import {ImpactNFTBase} from "../src/common/ImpactNFTBase.sol";

contract CleanupActionNFTTest is BaseTest {
    uint256 cid;
    bytes32 leafAlice;
    bytes32 leafBob;
    bytes32 root;

    function setUp() public override {
        super.setUp();
        vm.prank(organizer);
        cid = cleanups.createCampaign(
            "Limpieza rio Tinguiririca",
            "San Fernando",
            -34_585_000,
            -70_989_000,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );
        leafAlice = _leaf(alice, cid, 3_500);
        leafBob = _leaf(bob, cid, 1_500);
        root = Hashes.commutativeKeccak256(leafAlice, leafBob);
    }

    function _leaf(address who, uint256 campaignId, uint96 grams) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(who, campaignId, grams))));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function _finalize(uint96 total) internal {
        skip(1 days);
        vm.prank(verifier);
        cleanups.finalizeCampaign(cid, root, total, EV, URI);
    }

    function test_ClaimSoulboundBadge() public {
        _finalize(5_000);
        vm.prank(bob); // un relayer puede pagar el gas; el NFT va al participante
        uint256 id = cleanups.claim(alice, cid, 3_500, _proof(leafBob));

        assertEq(cleanups.ownerOf(id), alice);
        assertTrue(cleanups.locked(id));
        assertEq(cleanups.gramsCollectedBy(alice), 3_500);
        assertEq(cleanups.actionsBy(alice), 1);
        assertEq(cleanups.getCampaign(cid).claims, 1);
        assertTrue(cleanups.supportsInterface(0xb45a3c0e)); // ERC-5192

        vm.prank(alice);
        vm.expectRevert(CleanupActionNFT.Soulbound.selector);
        cleanups.transferFrom(alice, bob, id);
    }

    function test_RevertWhen_DoubleClaim() public {
        _finalize(5_000);
        cleanups.claim(alice, cid, 3_500, _proof(leafBob));
        vm.expectRevert(abi.encodeWithSelector(CleanupActionNFT.AlreadyClaimed.selector, cid, alice));
        cleanups.claim(alice, cid, 3_500, _proof(leafBob));
    }

    function test_RevertWhen_InflatedGrams() public {
        _finalize(5_000);
        vm.expectRevert(CleanupActionNFT.InvalidProof.selector);
        cleanups.claim(alice, cid, 9_999, _proof(leafBob));
    }

    function test_RevertWhen_ClaimsExceedWeighedTotal() public {
        _finalize(4_000);
        cleanups.claim(alice, cid, 3_500, _proof(leafBob));
        vm.expectRevert(
            abi.encodeWithSelector(CleanupActionNFT.ClaimExceedsTotal.selector, uint96(500), uint96(1_500))
        );
        cleanups.claim(bob, cid, 1_500, _proof(leafAlice));
    }

    function test_RevertWhen_FinalizeBeforeEnd() public {
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(CleanupActionNFT.CampaignNotEnded.selector, cid));
        cleanups.finalizeCampaign(cid, root, 5_000, EV, URI);
    }

    function test_RevertWhen_OrganizerFinalizesOwnCampaign() public {
        vm.startPrank(admin);
        cleanups.grantRole(cleanups.VERIFIER_ROLE(), organizer);
        vm.stopPrank();
        skip(1 days);
        vm.prank(organizer);
        vm.expectRevert(abi.encodeWithSelector(ImpactNFTBase.SelfVerification.selector, cid, organizer));
        cleanups.finalizeCampaign(cid, root, 5_000, EV, URI);
    }

    function test_RevertWhen_ClaimBeforeFinalize() public {
        vm.expectRevert(abi.encodeWithSelector(CleanupActionNFT.CampaignNotFinalized.selector, cid));
        cleanups.claim(alice, cid, 3_500, _proof(leafBob));
    }

    function test_OwnerCanBurnBadge() public {
        _finalize(5_000);
        uint256 id = cleanups.claim(alice, cid, 3_500, _proof(leafBob));
        assertTrue(_startsWith(cleanups.tokenURI(id), "data:application/json;base64,"));
        vm.prank(alice);
        cleanups.burn(id);
        assertFalse(cleanups.exists(id));
        assertEq(cleanups.gramsCollectedBy(alice), 3_500);
    }
}
