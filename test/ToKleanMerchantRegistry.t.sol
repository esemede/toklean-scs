// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MarketplaceBase} from "./MarketplaceBase.t.sol";
import {ToKleanMerchantRegistry} from "../src/marketplace/ToKleanMerchantRegistry.sol";

contract ToKleanMerchantRegistryTest is MarketplaceBase {
    function test_MerchantLifecycle() public {
        address shop = makeAddr("shop");
        vm.prank(shop);
        registry.applyAsMerchant("ipfs://bafyshop");
        assertEq(uint8(registry.getMerchant(shop).status), uint8(ToKleanMerchantRegistry.Status.Pending));
        assertFalse(registry.isApproved(shop));
        assertEq(registry.getMerchant(shop).profileHash, keccak256("ipfs://bafyshop"));

        vm.prank(merchantAdmin);
        registry.reviewMerchant(shop, false);
        assertEq(uint8(registry.getMerchant(shop).status), uint8(ToKleanMerchantRegistry.Status.Rejected));

        // Puede volver a postular
        vm.prank(shop);
        registry.applyAsMerchant("ipfs://bafyshop2");
        vm.prank(merchantAdmin);
        registry.reviewMerchant(shop, true);
        assertTrue(registry.isApproved(shop));

        vm.prank(merchantAdmin);
        registry.setSuspended(shop, true);
        assertFalse(registry.isApproved(shop));
        assertEq(uint8(registry.getMerchant(shop).status), uint8(ToKleanMerchantRegistry.Status.Suspended));
        vm.prank(merchantAdmin);
        registry.setSuspended(shop, false);
        assertTrue(registry.isApproved(shop));
    }

    function test_UpdateProfileOnlyWhenPendingOrApproved() public {
        vm.prank(seller);
        registry.updateProfile("ipfs://new");
        assertEq(registry.getMerchant(seller).profileHash, keccak256("ipfs://new"));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMerchantRegistry.NotMerchant.selector, stranger));
        registry.updateProfile("ipfs://x");
    }

    function test_RevertWhen_InvalidProfileUri() public {
        vm.startPrank(stranger);
        vm.expectRevert(ToKleanMerchantRegistry.InvalidUri.selector);
        registry.applyAsMerchant("");
        vm.expectRevert(ToKleanMerchantRegistry.InvalidUri.selector);
        registry.applyAsMerchant(string(new bytes(257)));
        vm.stopPrank();
    }

    function test_RevertWhen_ReappliesWhileRegistered() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMerchantRegistry.AlreadyRegistered.selector, seller));
        registry.applyAsMerchant("ipfs://x");
    }

    function test_RevertWhen_ReviewRulesBroken() public {
        address shop = makeAddr("shop");
        vm.prank(shop);
        registry.applyAsMerchant("ipfs://bafyshop");

        bytes32 role = registry.MERCHANT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        registry.reviewMerchant(shop, true);

        vm.startPrank(merchantAdmin);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMerchantRegistry.NotPending.selector, stranger));
        registry.reviewMerchant(stranger, true);
        // Sólo se suspende a un comercio aprobado y sólo se reintegra a uno suspendido
        vm.expectRevert(abi.encodeWithSelector(ToKleanMerchantRegistry.NotMerchant.selector, shop));
        registry.setSuspended(shop, true);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMerchantRegistry.NotSuspended.selector, seller));
        registry.setSuspended(seller, false);
        vm.stopPrank();
    }

    function test_SalesAndRatingsOnlyFromMarketplace() public {
        bytes32 role = registry.MARKETPLACE_ROLE();
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        registry.recordSale(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        registry.recordRating(seller, 5);
        vm.stopPrank();

        vm.startPrank(address(market));
        registry.recordRating(seller, 5);
        registry.recordRating(seller, 4);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMerchantRegistry.InvalidScore.selector, 0));
        registry.recordRating(seller, 0);
        vm.expectRevert(abi.encodeWithSelector(ToKleanMerchantRegistry.InvalidScore.selector, 6));
        registry.recordRating(seller, 6);
        vm.stopPrank();

        (uint256 avg, uint256 count) = registry.ratingOf(seller);
        assertEq(count, 2);
        assertEq(avg, 450);
        (avg, count) = registry.ratingOf(stranger);
        assertEq(count, 0);
        assertEq(avg, 0);
    }

    function test_ConstructorRejectsZeroAdmin() public {
        vm.expectRevert(ToKleanMerchantRegistry.ZeroAddress.selector);
        new ToKleanMerchantRegistry(address(0));
    }
}
