// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BaseTest} from "./Base.t.sol";
import {TreeNFT} from "../src/TreeNFT.sol";
import {ImpactNFTBase} from "../src/common/ImpactNFTBase.sol";

contract TreeNFTTest is BaseTest {
    int32 constant LAT = -34_585_000; // San Fernando, Chile
    int32 constant LON = -70_989_000;

    function _plant() internal returns (uint256 id) {
        vm.prank(alice);
        id = trees.plant("Quillaja saponaria", LAT, LON, 0, EV, URI);
    }

    function test_PlantMintsPendingTree() public {
        uint256 id = _plant();
        assertEq(trees.ownerOf(id), alice);
        TreeNFT.Tree memory t = trees.getTree(id);
        assertEq(t.planter, alice);
        assertEq(uint8(t.status), uint8(TreeNFT.TreeStatus.Pending));
        assertEq(t.latE6, LAT);
        assertEq(trees.checkpointCount(id), 1);
        assertEq(trees.estimatedCo2Kg(id), 0);
    }

    function test_VerifyAndTrackGrowth() public {
        uint256 id = _plant();
        vm.prank(verifier);
        trees.verifyPlanting(id, true, 22, EV, URI);
        assertEq(trees.verifiedTreesBy(alice), 1);
        assertEq(trees.totalVerifiedTrees(), 1);

        skip(365 days);
        vm.prank(verifier);
        trees.recordCheckpoint(id, 180, 90, TreeNFT.TreeStatus.Growing, EV, URI);
        assertEq(trees.estimatedCo2Kg(id), 22);

        skip(365 days);
        vm.prank(verifier);
        trees.recordCheckpoint(id, 400, 95, TreeNFT.TreeStatus.Mature, EV, URI);
        assertEq(trees.estimatedCo2Kg(id), 44);

        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreeNFT.InvalidTransition.selector, TreeNFT.TreeStatus.Mature, TreeNFT.TreeStatus.Growing
            )
        );
        trees.recordCheckpoint(id, 400, 95, TreeNFT.TreeStatus.Growing, EV, URI);

        vm.prank(verifier);
        trees.recordCheckpoint(id, 400, 0, TreeNFT.TreeStatus.Dead, EV, URI);
        skip(365 days);
        assertEq(trees.estimatedCo2Kg(id), 44, "CO2 stops accruing after death");
        assertEq(trees.getCheckpoints(id).length, 5);
    }

    function test_RevertWhen_PlanterSelfVerifies() public {
        vm.startPrank(admin);
        trees.grantRole(trees.VERIFIER_ROLE(), alice);
        vm.stopPrank();
        uint256 id = _plant();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ImpactNFTBase.SelfVerification.selector, id, alice));
        trees.verifyPlanting(id, true, 20, EV, URI);
    }

    function test_RevertWhen_NotVerifier() public {
        uint256 id = _plant();
        bytes32 role = trees.VERIFIER_ROLE();
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, role)
        );
        trees.verifyPlanting(id, true, 20, EV, URI);
    }

    function test_RejectedTreeCannotBeTracked() public {
        uint256 id = _plant();
        vm.prank(verifier);
        trees.verifyPlanting(id, false, 0, EV, URI);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(TreeNFT.InvalidStatus.selector, id, TreeNFT.TreeStatus.Rejected)
        );
        trees.recordCheckpoint(id, 10, 50, TreeNFT.TreeStatus.Growing, EV, URI);
    }

    function test_RevertWhen_Co2EstimateTooHigh() public {
        uint256 id = _plant();
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(TreeNFT.Co2EstimateTooHigh.selector, uint32(501)));
        trees.verifyPlanting(id, true, 501, EV, URI);
    }

    function test_SponsorshipTransferKeepsPlanter() public {
        uint256 id = _plant();
        vm.prank(alice);
        trees.transferFrom(alice, bob, id);
        assertEq(trees.ownerOf(id), bob);
        assertEq(trees.getTree(id).planter, alice);

        vm.prank(alice); // el plantador puede seguir subiendo evidencias
        trees.reportProgress(id, EV, URI);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(TreeNFT.NotOwnerOrPlanter.selector, id, verifier));
        trees.reportProgress(id, EV, URI);
    }

    function test_RevertWhen_EmptyEvidence() public {
        vm.prank(alice);
        vm.expectRevert(ImpactNFTBase.EmptyEvidence.selector);
        trees.plant("Peumo", LAT, LON, 0, bytes32(0), URI);
    }

    function test_RevertWhen_Paused() public {
        vm.prank(admin);
        trees.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        trees.plant("Peumo", LAT, LON, 0, EV, URI);
    }

    function test_TokenURIIsOnchainJson() public {
        uint256 id = _plant();
        string memory uri = trees.tokenURI(id);
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
    }

    function testFuzz_Coordinates(int32 lat, int32 lon) public {
        bool valid = lat >= -90e6 && lat <= 90e6 && lon >= -180e6 && lon <= 180e6;
        vm.prank(alice);
        if (!valid) vm.expectRevert(ImpactNFTBase.InvalidCoordinates.selector);
        trees.plant("Espino", lat, lon, 0, EV, URI);
    }
}
