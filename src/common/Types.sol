// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Tipos de material reciclable soportados por la trazabilidad ToKlean.
/// @dev `EWaste` (RAEE) y `Batteries` son productos prioritarios de la Ley REP (Ley 20.920)
///      y se tratan como residuos peligrosos (D.S. 148/2003) antes de su valorización.
enum MaterialType {
    PET,
    HDPE,
    LDPE,
    PP,
    PS,
    OtherPlastic,
    Aluminum,
    Steel,
    Glass,
    PaperCardboard,
    Tetrapak,
    EWaste,
    Batteries,
    Textile,
    Organic,
    Other
}

library MaterialNames {
    function name(MaterialType m) internal pure returns (string memory) {
        string[16] memory names = [
            "PET",
            "HDPE",
            "LDPE",
            "PP",
            "PS",
            "Otro plastico",
            "Aluminio",
            "Acero",
            "Vidrio",
            "Papel y carton",
            "Tetrapak",
            "RAEE",
            "Baterias",
            "Textil",
            "Organico",
            "Otro"
        ];
        return names[uint256(m)];
    }

    function isHazardous(MaterialType m) internal pure returns (bool) {
        return m == MaterialType.EWaste || m == MaterialType.Batteries;
    }
}
