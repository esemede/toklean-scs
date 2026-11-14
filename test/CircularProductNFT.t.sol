// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";
import {RecyclingBatchNFT} from "../src/RecyclingBatchNFT.sol";
import {ImpactNFTBase} from "../src/common/ImpactNFTBase.sol";
import {EnergyFactors, EnergyType, EnergyUse} from "../src/product/EnergyFactors.sol";

contract CircularProductNFTTest is BaseTest {
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
            _energy(renewable),
            _input(),
            idea
        );
    }

    function test_ManufactureConsumesBatch() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 5_000, 0);

        assertEq(products.ownerOf(id), alice);
        assertEq(
            uint256(products.getProduct(id).recycledGrams) * 10_000 / products.getProduct(id).massGrams, 8000
        );
        assertEq(
            uint256(products.getManufacturingData(id).co2eGrams) * 1000 / products.getProduct(id).massGrams,
            500
        );
        assertEq(batches.availableGrams(batchId), 2_000);
        assertEq(batches.getBatch(batchId).consumedGrams, 8_000);
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
        products.manufacture(alice, "Otra banca", 10_000, _inputs(batchId, 1), _energy(8000), _input(), 0);
    }

    function test_RevertWhen_UsingSomeoneElsesBatch() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        address other = makeAddr("otherManufacturer");
        vm.startPrank(admin);
        products.grantRole(products.MANUFACTURER_ROLE(), other);
        vm.stopPrank();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ImpactNFTBase.NotTokenOwner.selector, batchId, other));
        products.manufacture(alice, "Robo", 10_000, _inputs(batchId, 1_000), _energy(8000), _input(), 0);
    }

    function test_RevertWhen_RecycledExceedsMass() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                CircularProductNFT.RecycledExceedsMass.selector, uint96(6_000), uint96(5_000)
            )
        );
        products.manufacture(alice, "x", 5_000, _inputs(batchId, 6_000), _energy(8000), _input(), 0);
    }

    function test_CertifyCleanManufacturing() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 5_000, 0);
        vm.prank(verifier);
        products.certify(id, true, EV, URI);
        assertEq(uint8(products.getProduct(id).status), uint8(CircularProductNFT.CleanStatus.Certified));

        vm.prank(verifier);
        products.certify(id, false, EV, URI);
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

    function test_EnergyIsComputedFromTypeAndAmount() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 0, 0);
        CircularProductNFT.ManufacturingData memory d = products.getManufacturingData(id);
        assertEq(d.energyWh, 10_000);
        assertEq(d.renewableEnergyBps, 8000);
        // 8 kWh x 30 + 2 kWh x 480 = 1.200 g de energía + 3.800 g de proceso
        assertEq(d.co2eGrams, 5_000);
    }

    function test_DieselWoodAndOtherEmitMoreThanGrid() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        EnergyUse[] memory e = new EnergyUse[](4);
        e[0] = EnergyUse(EnergyType.Diesel, 1_000); // 1 kWh x 850
        e[1] = EnergyUse(EnergyType.Gasoline, 1_000); // 1 kWh x 1000
        e[2] = EnergyUse(EnergyType.Wood, 1_000); // 1 kWh x 400
        e[3] = EnergyUse(EnergyType.Other, 1_000); // 1 kWh x 800
        CircularProductNFT.ManufacturingInput memory data = _input();
        data.processCo2eGrams = 0;
        vm.prank(manufacturer);
        uint256 id = products.manufacture(alice, "Banca", 10_000, _inputs(batchId, 8_000), e, data, 0);
        CircularProductNFT.ManufacturingData memory d = products.getManufacturingData(id);
        assertEq(d.co2eGrams, 850 + 1000 + 400 + 800);
        assertEq(d.renewableEnergyBps, 0);
        assertFalse(products.meetsCleanCriteria(id));
    }

    function test_AdminCanTuneFactorsButOldProductsKeepTheirs() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 4_000, 10_000, 8000, 0, 0);
        vm.prank(admin);
        energyFactors.setFactor(EnergyType.Grid, 100);
        assertEq(energyFactors.factors(1), 100);
        assertEq(products.getManufacturingData(id).co2eGrams, 5_000);

        vm.prank(manufacturer);
        uint256 id2 =
            products.manufacture(alice, "Otra", 10_000, _inputs(batchId, 4_000), _energy(8000), _input(), 0);
        // 8 kWh x 30 + 2 kWh x 100 + 3.800 de proceso
        assertEq(products.getManufacturingData(id2).co2eGrams, 240 + 200 + 3_800);
    }

    function test_RevertWhen_FactorEditedByNonAdminOrTooHigh() public {
        vm.prank(alice);
        vm.expectRevert();
        energyFactors.setFactor(EnergyType.Grid, 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EnergyFactors.FactorTooHigh.selector, uint32(5_001)));
        energyFactors.setFactor(EnergyType.Grid, 5_001);
    }

    function test_ProductWithoutEnergyDataCannotBeCertified() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        EnergyUse[] memory none = new EnergyUse[](0);
        vm.prank(manufacturer);
        uint256 id = products.manufacture(alice, "x", 10_000, _inputs(batchId, 8_000), none, _input(), 0);
        assertEq(products.getManufacturingData(id).renewableEnergyBps, 0);
        assertFalse(products.meetsCleanCriteria(id));
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(CircularProductNFT.CriteriaNotMet.selector, id));
        products.certify(id, true, EV, URI);
    }

    function test_PreviewMatchesStoredAndStatusIsReadable() public {
        uint256 batchId = _batchAtManufacturer(10_000);
        uint256 id = _manufacture(batchId, 8_000, 10_000, 8000, 0, 0);
        assertEq(uint8(products.statusOf(id)), uint8(CircularProductNFT.CleanStatus.Declared));
        assertEq(products.manufacturerOf(id), manufacturer);
        assertEq(products.tokenURI(id), products.imageBaseURI());
    }
}
