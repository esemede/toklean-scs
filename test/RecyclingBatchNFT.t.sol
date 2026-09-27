// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {RecyclingBatchNFT} from "../src/RecyclingBatchNFT.sol";
import {MaterialType} from "../src/common/Types.sol";

contract RecyclingBatchNFTTest is BaseTest {
    function _register(MaterialType m, uint96 grams) internal returns (uint256 id) {
        vm.prank(collector);
        id = batches.registerCollection(m, grams, "San Fernando", EV, URI);
    }

    function test_FullChainOfCustody() public {
        uint256 id = _batchAtManufacturer(10_000);
        assertEq(batches.ownerOf(id), manufacturer);
        RecyclingBatchNFT.Batch memory b = batches.getBatch(id);
        assertEq(uint8(b.stage), uint8(RecyclingBatchNFT.Stage.AtManufacturer));
        assertEq(b.collector, collector);
        assertEq(batches.getSteps(id).length, 6);
        assertEq(batches.verifiedGramsByCollector(collector), 10_000);
        assertEq(batches.processedGramsByMaterial(MaterialType.PET), 10_000);
        assertEq(batches.availableGrams(id), 10_000);
    }

    function test_CollectorCreditUsesCenterWeight() public {
        uint256 id = _register(MaterialType.Aluminum, 5_000);
        vm.prank(collector);
        batches.dispatch(id, center);
        vm.prank(center);
        batches.acceptBatch(id, 4_200, EV, URI);
        assertEq(batches.verifiedGramsByCollector(collector), 4_200);
    }

    function test_RevertWhen_FreeTransfer() public {
        uint256 id = _register(MaterialType.Glass, 1_000);
        vm.prank(collector);
        vm.expectRevert(RecyclingBatchNFT.TransferOnlyViaHandoff.selector);
        batches.transferFrom(collector, center, id);
    }

    function test_RevertWhen_WeightInflated() public {
        uint256 id = _register(MaterialType.PET, 10_000);
        vm.prank(collector);
        batches.dispatch(id, center);
        vm.prank(center);
        batches.acceptBatch(id, 10_200, EV, URI); // +2 % tolerado

        vm.prank(center);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecyclingBatchNFT.WeightExceedsTolerance.selector, uint96(10_200), uint96(10_201)
            )
        );
        batches.recordSorting(id, 10_201, EV, URI); // la clasificación nunca sube el peso
    }

    function test_RevertWhen_AcceptExceedsTolerance() public {
        uint256 id = _register(MaterialType.PET, 10_000);
        vm.prank(collector);
        batches.dispatch(id, center);
        vm.prank(center);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecyclingBatchNFT.WeightExceedsTolerance.selector, uint96(10_000), uint96(10_201)
            )
        );
        batches.acceptBatch(id, 10_201, EV, URI);
    }

    function test_RevertWhen_DispatchToWrongRole() public {
        uint256 id = _register(MaterialType.PET, 1_000);
        bytes32 centerRole = batches.COLLECTION_CENTER_ROLE();
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(RecyclingBatchNFT.MissingRole.selector, recycler, centerRole));
        batches.dispatch(id, recycler);
    }

    function test_HazardousRequiresAuthorizedHandler() public {
        uint256 id = _register(MaterialType.EWaste, 3_000);
        assertTrue(batches.getBatch(id).hazardous);
        bytes32 hazardousRole = batches.HAZARDOUS_HANDLER_ROLE();
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(RecyclingBatchNFT.MissingRole.selector, center, hazardousRole));
        batches.dispatch(id, center);

        vm.startPrank(admin);
        batches.grantRole(batches.HAZARDOUS_HANDLER_ROLE(), center);
        vm.stopPrank();
        vm.prank(collector);
        batches.dispatch(id, center);
        vm.prank(center);
        batches.acceptBatch(id, 3_000, EV, URI);
        assertEq(batches.ownerOf(id), center);
    }

    function test_OnlyPendingRecipientAccepts() public {
        uint256 id = _register(MaterialType.PET, 1_000);
        vm.prank(collector);
        batches.dispatch(id, center);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RecyclingBatchNFT.NotPendingRecipient.selector, id, bob));
        batches.acceptBatch(id, 1_000, EV, URI);

        vm.prank(collector);
        batches.cancelDispatch(id);
        vm.prank(center);
        vm.expectRevert(abi.encodeWithSelector(RecyclingBatchNFT.NotPendingRecipient.selector, id, center));
        batches.acceptBatch(id, 1_000, EV, URI);
    }

    function test_RevertWhen_RoleRevokedBeforeAccept() public {
        uint256 id = _register(MaterialType.PET, 1_000);
        vm.prank(collector);
        batches.dispatch(id, center);
        bytes32 centerRole = batches.COLLECTION_CENTER_ROLE();
        vm.prank(admin);
        batches.revokeRole(centerRole, center);
        vm.prank(center);
        vm.expectRevert(abi.encodeWithSelector(RecyclingBatchNFT.MissingRole.selector, center, centerRole));
        batches.acceptBatch(id, 1_000, EV, URI);
    }

    function test_VerifierRejectsContaminatedBatch() public {
        uint256 id = _register(MaterialType.PET, 1_000);
        vm.prank(verifier);
        batches.reject(id, EV, URI);
        assertEq(uint8(batches.getBatch(id).stage), uint8(RecyclingBatchNFT.Stage.Rejected));
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecyclingBatchNFT.InvalidStage.selector, id, RecyclingBatchNFT.Stage.Rejected
            )
        );
        batches.dispatch(id, center);
    }

    function test_RevertWhen_ConsumeWithoutRole() public {
        uint256 id = _batchAtManufacturer(1_000);
        vm.prank(manufacturer);
        vm.expectRevert();
        batches.consume(id, 100, manufacturer, 1);
    }

    function testFuzz_MassNeverIncreasesThroughProcessing(uint96 declared, uint96 sorted, uint96 output)
        public
    {
        declared = uint96(bound(declared, 1, 1e12));
        uint256 id = _register(MaterialType.HDPE, declared);
        vm.prank(collector);
        batches.dispatch(id, center);
        vm.prank(center);
        batches.acceptBatch(id, declared, EV, URI);

        vm.prank(center);
        if (sorted == 0 || sorted > declared) {
            vm.expectRevert();
            batches.recordSorting(id, sorted, EV, URI);
            return;
        }
        batches.recordSorting(id, sorted, EV, URI);
        vm.prank(center);
        batches.dispatch(id, recycler);
        vm.prank(recycler);
        batches.acceptBatch(id, sorted, EV, URI);
        vm.prank(recycler);
        if (output == 0 || output > sorted) {
            vm.expectRevert();
            batches.recordProcessing(id, output, EV, URI);
            return;
        }
        batches.recordProcessing(id, output, EV, URI);
        assertLe(batches.getBatch(id).currentGrams, declared);
    }
}
