// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";
import {RecyclingBatchNFT} from "../src/RecyclingBatchNFT.sol";
import {ImpactNFTBase} from "../src/common/ImpactNFTBase.sol";

contract CircularProductNFTTest is BaseTest {
    function _data(uint16 renewableBps, uint64 co2eGrams)
        internal
        pure
        returns (CircularProductNFT.ManufacturingData memory)
    {
        return CircularProductNFT.ManufacturingData({
            energyWh: 1_500,
            waterLiters: 3,
            co2eGrams: co2eGrams,
            wasteGrams: 20,
            renewableEnergyBps: renewableBps,
            reportHash: keccak256("lca-report"),
            reportURI: "ipfs://lca",
            facility: "Planta Rancagua"
        });
    }

    function _inputs(uint256 batchId, uint96 grams)
        internal
        pure
        returns (CircularProductNFT.MaterialInput[] memory arr)
    {
        arr = new CircularProductNFT.MaterialInput[](1);
        arr[0] = CircularProductNFT.MaterialInput({batchId: batchId, grams: grams});
    }

    function _manufacture(
        uint256 batchId,
        uint96 recycled,
        uint96 mass,
        uint16 renewable,
        uint64 co2e,
        uint256 idea
    ) internal returns (uint256) {
        vm.prank(manufacturer);
        return products.manufacture(
            alice,
            "Banca de plastico reciclado",
            mass,
            _inputs(batchId, recycled),
            _data(renewable, co2e),
            idea
        );
    }

    function test_ManufactureConsumesBatch() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 5_000, 0);

        assertEq(products.ownerOf(id), alice);
        assertEq(products.recycledContentBps(id), 8000);
        assertEq(products.co2eGramsPerKg(id), 500);
        assertEq(batches.availableGrams(batchId), 2_000);
        assertEq(products.getInputs(id)[0].batchId, batchId);
        assertEq(products.recycledGramsUsedBy(manufacturer), 8_000);
        assertTrue(products.meetsCleanCriteria(id));
    }

    function test_RevertWhen_DoubleSpendingMaterial() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        _manufacture(batchId, 10_000, 10_000, 8000, 5_000, 0);
        assertEq(uint8(batches.getBatch(batchId).stage), uint8(RecyclingBatchNFT.Stage.Consumed));

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecyclingBatchNFT.InvalidStage.selector, batchId, RecyclingBatchNFT.Stage.Consumed
            )
        );
        products.manufacture(alice, "Otra banca", 10_000, _inputs(batchId, 1), _data(8000, 5_000), 0);
    }

    function test_RevertWhen_UsingSomeoneElsesBatch() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        address other = makeAddr("otherManufacturer");
        vm.startPrank(admin);
        products.grantRole(products.MANUFACTURER_ROLE(), other);
        vm.stopPrank();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ImpactNFTBase.NotTokenOwner.selector, batchId, other));
        products.manufacture(alice, "Robo", 10_000, _inputs(batchId, 1_000), _data(8000, 5_000), 0);
    }

    function test_RevertWhen_RecycledExceedsMass() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                CircularProductNFT.RecycledExceedsMass.selector, uint96(6_000), uint96(5_000)
            )
        );
        products.manufacture(alice, "x", 5_000, _inputs(batchId, 6_000), _data(8000, 1), 0);
    }

    function test_CertifyCleanManufacturing() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 5_000, 0);
        vm.prank(verifier);
        products.certify(id, true, EV, URI);
        assertEq(uint8(products.getProduct(id).status), uint8(CircularProductNFT.CleanStatus.Certified));

        vm.prank(verifier);
        products.revokeCertification(id, EV, URI);
        assertEq(uint8(products.getProduct(id).status), uint8(CircularProductNFT.CleanStatus.Revoked));
    }

    function test_RevertWhen_CertifyingDirtyManufacturing() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        // 30 % renovable < 50 % mínimo
        uint256 id = _manufacture(batchId, 8_000, 10_000, 3000, 5_000, 0);
        assertFalse(products.meetsCleanCriteria(id));
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(CircularProductNFT.CriteriaNotMet.selector, id));
        products.certify(id, true, EV, URI);

        vm.prank(verifier);
        products.certify(id, false, EV, URI);
        assertEq(uint8(products.getProduct(id).status), uint8(CircularProductNFT.CleanStatus.Rejected));
    }

    function test_RevertWhen_ManufacturerSelfCertifies() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 5_000, 0);
        vm.startPrank(admin);
        products.grantRole(products.VERIFIER_ROLE(), manufacturer);
        vm.stopPrank();
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(ImpactNFTBase.SelfVerification.selector, id, manufacturer));
        products.certify(id, true, EV, URI);
    }

    function test_LinksInspiringIdea() public {
        vm.prank(bob);
        uint256 ideaId = ideas.proposeIdea("Bancas de PET", "Plasticos", keccak256("bancas"), "");
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 5_000, ideaId);
        assertEq(products.getProduct(id).inspiredByIdea, ideaId);

        vm.expectRevert(); // idea inexistente
        _manufacture(batchId, 1_000, 10_000, 8000, 5_000, 999);
    }

    function test_ReturnForRecycling() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 5_000, 0);
        vm.prank(alice);
        products.returnForRecycling(id);
        assertTrue(products.getProduct(id).returnedForRecycling);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CircularProductNFT.AlreadyReturned.selector, id));
        products.returnForRecycling(id);
        assertTrue(_startsWith(products.tokenURI(id), "data:application/json;base64,"));
    }
}
