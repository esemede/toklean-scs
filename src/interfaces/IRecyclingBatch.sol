// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MaterialType} from "../common/Types.sol";

/// @notice Interfaz mínima que consumen los contratos de producto para descontar material reciclado.
interface IRecyclingBatch {
    function consume(uint256 batchId, uint96 grams, address operator, uint256 productId) external;
    function availableGrams(uint256 batchId) external view returns (uint96);
    function materialOf(uint256 batchId) external view returns (MaterialType);
}
