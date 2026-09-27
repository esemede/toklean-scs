// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice ERC-5192: Minimal Soulbound NFTs.
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);

    function locked(uint256 tokenId) external view returns (bool);
}
