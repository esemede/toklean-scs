// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Tipos de energía usados en la fabricación de un producto.
enum EnergyType {
    Renewable, // solar, eólica, hidráulica, geotérmica
    Grid, // red eléctrica
    Diesel, // generador diésel
    Gasoline, // generador a bencina
    Wood, // leña
    Other
}

struct EnergyUse {
    EnergyType kind;
    uint64 wh;
}

/// @title EnergyFactors
/// @notice Tabla de factores de emisión de la energía (gCO2e por kWh) por tipo, configurable por el admin, y el
///         cálculo de emisiones y % renovable de una lista de usos de energía. La consume `CircularProductNFT`.
/// @dev Los valores iniciales son referencias internacionales redondeadas (revisar y ajustar por gobernanza):
///      - Renovable 30: ciclo de vida, IPCC AR5 WGIII Anexo III (eólica 11, hidráulica 24, geotérmica 38, FV 41-48).
///      - Red 480: promedio mundial de generación eléctrica (Ember / IEA, ~470-480). Usar el factor oficial del país.
///      - Diésel 850: IPCC 2006 (74,1 kgCO2/GJ = 267 g/kWh de combustible) / ~31 % de eficiencia del grupo electrógeno.
///      - Bencina 1000: IPCC 2006 (69,3 kgCO2/GJ = 249 g/kWh) / ~25 % de eficiencia.
///      - Leña 400: IPCC 2006 (112 kgCO2/GJ = 403 g/kWh térmico), contando el carbono biogénico (criterio prudente).
///      - Otro 800: prudente, cercano al carbón (IPCC AR5: 820).
///      Cambiar un factor no altera los productos ya fabricados: sus emisiones quedaron guardadas al fabricarlos.
contract EnergyFactors is AccessControl {
    uint32 public constant MAX_FACTOR = 5_000; // tope de sensatez, gCO2e/kWh
    uint16 internal constant BPS = 10_000;

    uint32[6] public factors;

    event FactorUpdated(EnergyType indexed kind, uint32 gramsPerKWh);

    error ZeroAddress();
    error FactorTooHigh(uint32 value);
    error Overflow();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        factors = [uint32(30), 480, 850, 1000, 400, 800];
    }

    function setFactor(EnergyType kind, uint32 gramsPerKWh) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gramsPerKWh > MAX_FACTOR) revert FactorTooHigh(gramsPerKWh);
        factors[uint256(kind)] = gramsPerKWh;
        emit FactorUpdated(kind, gramsPerKWh);
    }

    /// @notice Energía total (Wh), emisiones (g CO2e) y % renovable (bps) de una lista de usos, con los factores actuales.
    function totals(EnergyUse[] calldata energy)
        external
        view
        returns (uint64 totalWh, uint64 co2eGrams, uint16 renewableBps)
    {
        uint256 wh;
        uint256 renewableWh;
        uint256 grams;
        for (uint256 i; i < energy.length; ++i) {
            uint256 w = energy[i].wh;
            wh += w;
            if (energy[i].kind == EnergyType.Renewable) renewableWh += w;
            grams += w * factors[uint256(energy[i].kind)] / 1000;
        }
        if (wh > type(uint64).max || grams > type(uint64).max) revert Overflow();
        totalWh = uint64(wh);
        co2eGrams = uint64(grams);
        renewableBps = wh == 0 ? 0 : uint16(renewableWh * BPS / wh);
    }
}
