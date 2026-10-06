// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ToKleanToken} from "./ToKleanToken.sol";

/// @title TokenFaucet
/// @notice Entrega TKN de prueba (50 por dirección cada 24 h). Sólo para testnets: el constructor
///         se niega a desplegarse en redes principales conocidas.
/// @dev Requiere MINTER_ROLE sobre el token. El tope de suministro de TKN sigue aplicando.
contract TokenFaucet is AccessControl {
    ToKleanToken public immutable token;
    uint256 public amount = 50 ether;
    uint256 public cooldown = 1 days;
    bool public enabled = true;
    mapping(address account => uint256 timestamp) public lastClaim;

    event Claimed(address indexed account, uint256 amount);
    event ConfigUpdated(uint256 amount, uint256 cooldown, bool enabled);

    error ZeroAddress();
    error MainnetNotAllowed(uint256 chainId);
    error FaucetDisabled();
    error CooldownActive(uint256 availableAt);

    constructor(ToKleanToken token_, address admin) {
        if (address(token_) == address(0) || admin == address(0)) revert ZeroAddress();
        uint256 id = block.chainid;
        if (id == 1 || id == 137 || id == 10 || id == 42161 || id == 8453 || id == 56 || id == 43114) {
            revert MainnetNotAllowed(id);
        }
        token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function claim() external {
        if (!enabled) revert FaucetDisabled();
        uint256 availableAt = lastClaim[msg.sender] + cooldown;
        if (lastClaim[msg.sender] != 0 && block.timestamp < availableAt) revert CooldownActive(availableAt);
        lastClaim[msg.sender] = block.timestamp;
        token.mint(msg.sender, token.TKN(), amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Segundos que faltan para poder reclamar de nuevo (0 = disponible).
    function secondsUntilClaim(address account) external view returns (uint256) {
        uint256 last = lastClaim[account];
        if (last == 0 || block.timestamp >= last + cooldown) return 0;
        return last + cooldown - block.timestamp;
    }

    function configure(uint256 amount_, uint256 cooldown_, bool enabled_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        amount = amount_;
        cooldown = cooldown_;
        enabled = enabled_;
        emit ConfigUpdated(amount_, cooldown_, enabled_);
    }
}
