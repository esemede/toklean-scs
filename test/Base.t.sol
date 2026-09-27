// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TreeNFT} from "../src/TreeNFT.sol";
import {RecyclingIdeaNFT} from "../src/RecyclingIdeaNFT.sol";
import {RecyclingBatchNFT} from "../src/RecyclingBatchNFT.sol";
import {CircularProductNFT} from "../src/CircularProductNFT.sol";
import {CleanupActionNFT} from "../src/CleanupActionNFT.sol";
import {IRecyclingBatch} from "../src/interfaces/IRecyclingBatch.sol";
import {MaterialType} from "../src/common/Types.sol";

abstract contract BaseTest is Test {
    address admin = makeAddr("admin");
    address verifier = makeAddr("verifier");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address collector = makeAddr("collector");
    address center = makeAddr("center");
    address recycler = makeAddr("recycler");
    address manufacturer = makeAddr("manufacturer");
    address organizer = makeAddr("organizer");

    bytes32 constant EV = keccak256("evidence");
    string constant URI = "ipfs://bafyevidence";

    TreeNFT trees;
    RecyclingIdeaNFT ideas;
    RecyclingBatchNFT batches;
    CircularProductNFT products;
    CleanupActionNFT cleanups;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        trees = new TreeNFT(admin, "ipfs://img/");
        ideas = new RecyclingIdeaNFT(admin, "ipfs://img/");
        batches = new RecyclingBatchNFT(admin, "ipfs://img/");
        products = new CircularProductNFT(
            admin,
            "ipfs://img/",
            IRecyclingBatch(address(batches)),
            IERC721(address(ideas)),
            CircularProductNFT.CleanCriteria({
                minRecycledContentBps: 3000, minRenewableEnergyBps: 5000, maxCo2eGramsPerKg: 2000
            })
        );
        cleanups = new CleanupActionNFT(admin, "ipfs://img/");

        vm.startPrank(admin);
        trees.grantRole(trees.VERIFIER_ROLE(), verifier);
        ideas.grantRole(ideas.VERIFIER_ROLE(), verifier);
        batches.grantRole(batches.VERIFIER_ROLE(), verifier);
        batches.grantRole(batches.COLLECTOR_ROLE(), collector);
        batches.grantRole(batches.COLLECTION_CENTER_ROLE(), center);
        batches.grantRole(batches.RECYCLER_ROLE(), recycler);
        batches.grantRole(batches.MANUFACTURER_ROLE(), manufacturer);
        batches.grantRole(batches.CONSUMER_ROLE(), address(products));
        products.grantRole(products.MANUFACTURER_ROLE(), manufacturer);
        products.grantRole(products.VERIFIER_ROLE(), verifier);
        cleanups.grantRole(cleanups.ORGANIZER_ROLE(), organizer);
        cleanups.grantRole(cleanups.VERIFIER_ROLE(), verifier);
        vm.stopPrank();
    }

    /// @dev Lleva un lote de PET desde la recolección hasta el fabricante.
    function _batchAtManufacturer(uint96 grams) internal returns (uint256 id) {
        vm.prank(collector);
        id = batches.registerCollection(MaterialType.PET, grams, "San Fernando - Punto limpio 1", EV, URI);
        vm.prank(collector);
        batches.dispatch(id, center);
        vm.prank(center);
        batches.acceptBatch(id, grams, EV, URI);
        vm.prank(center);
        batches.recordSorting(id, grams, EV, URI);
        vm.prank(center);
        batches.dispatch(id, recycler);
        vm.prank(recycler);
        batches.acceptBatch(id, grams, EV, URI);
        vm.prank(recycler);
        batches.recordProcessing(id, grams, EV, URI);
        vm.prank(recycler);
        batches.dispatch(id, manufacturer);
        vm.prank(manufacturer);
        batches.acceptBatch(id, grams, EV, URI);
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
