// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {RecyclingIdeaNFT} from "../src/RecyclingIdeaNFT.sol";
import {ImpactNFTBase} from "../src/common/ImpactNFTBase.sol";

contract RecyclingIdeaNFTTest is BaseTest {
    bytes32 constant CONTENT = keccak256("maceteros con botellas PET y riego por goteo");

    function _propose() internal returns (uint256 id) {
        vm.prank(alice);
        id = ideas.proposeIdea("Maceteros de PET con riego", "Plasticos", CONTENT, "ipfs://idea");
    }

    function test_ProposeRegistersAuthorAndRoyalty() public {
        uint256 id = _propose();
        RecyclingIdeaNFT.Idea memory i = ideas.getIdea(id);
        assertEq(i.author, alice);
        assertEq(ideas.ideaIdByContentHash(CONTENT), id);
        (address receiver, uint256 amount) = ideas.royaltyInfo(id, 1 ether);
        assertEq(receiver, alice);
        assertEq(amount, 0.05 ether);
        assertTrue(ideas.supportsInterface(0x2a55205a)); // ERC-2981
    }

    function test_RevertWhen_DuplicateContent() public {
        uint256 id = _propose();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RecyclingIdeaNFT.IdeaAlreadyRegistered.selector, id));
        ideas.proposeIdea("Copia", "Plasticos", CONTENT, "ipfs://copy");
    }

    function test_EndorseOncePerAccount() public {
        uint256 id = _propose();
        vm.prank(bob);
        ideas.endorse(id);
        assertEq(ideas.getIdea(id).endorsements, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RecyclingIdeaNFT.AlreadyEndorsed.selector, id, bob));
        ideas.endorse(id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RecyclingIdeaNFT.AuthorCannotEndorse.selector, id));
        ideas.endorse(id);
    }

    function test_ReviewAndImplement() public {
        uint256 id = _propose();
        vm.prank(verifier);
        ideas.review(id, RecyclingIdeaNFT.IdeaStatus.Approved, bytes32(0));
        vm.prank(verifier);
        ideas.registerImplementation(id, bob, EV, URI);
        vm.prank(verifier);
        ideas.registerImplementation(id, collector, EV, URI);

        RecyclingIdeaNFT.Idea memory i = ideas.getIdea(id);
        assertEq(uint8(i.status), uint8(RecyclingIdeaNFT.IdeaStatus.Implemented));
        assertEq(i.implementations, 2);
        assertEq(ideas.getImplementations(id)[0].implementer, bob);
    }

    function test_AuthorKeepsRoyaltyAfterTransfer() public {
        uint256 id = _propose();
        vm.prank(alice);
        ideas.transferFrom(alice, bob, id);
        (address receiver,) = ideas.royaltyInfo(id, 1 ether);
        assertEq(receiver, alice);
    }

    function test_RevertWhen_ImplementBeforeApproval() public {
        uint256 id = _propose();
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecyclingIdeaNFT.InvalidStatus.selector, id, RecyclingIdeaNFT.IdeaStatus.Proposed
            )
        );
        ideas.registerImplementation(id, bob, EV, URI);
    }

    function test_RevertWhen_ReviewRejectedIdea() public {
        uint256 id = _propose();
        vm.prank(verifier);
        ideas.review(id, RecyclingIdeaNFT.IdeaStatus.Rejected, bytes32(0));
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecyclingIdeaNFT.InvalidStatus.selector, id, RecyclingIdeaNFT.IdeaStatus.Rejected
            )
        );
        ideas.review(id, RecyclingIdeaNFT.IdeaStatus.Approved, bytes32(0));
    }

    function test_RevertWhen_TitleTooLong() public {
        bytes memory title = new bytes(121);
        for (uint256 k; k < title.length; ++k) {
            title[k] = "a";
        }
        vm.prank(alice);
        vm.expectRevert(RecyclingIdeaNFT.TitleTooLong.selector);
        ideas.proposeIdea(string(title), "x", CONTENT, "");
    }

    function test_TokenURIEscapesUserInput() public {
        vm.prank(alice);
        uint256 id = ideas.proposeIdea('Idea "con comillas"', "Vidrio", keccak256("q"), "");
        assertTrue(_startsWith(ideas.tokenURI(id), "data:application/json;base64,"));
    }
}
