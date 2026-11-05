// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ToKleanToken} from "../src/token/ToKleanToken.sol";
import {TokenFaucet} from "../src/token/TokenFaucet.sol";
import {ToKleanStaking} from "../src/staking/ToKleanStaking.sol";
import {ToKleanGovernance} from "../src/governance/ToKleanGovernance.sol";

/// @notice Despliega la economía ToKlean: token ERC-1155 (TKN/REC/POR), staking, DAO y (sólo testnet) faucet.
/// @dev Agrega sus direcciones a deployments/<chainId>.json sin tocar las de los NFTs de impacto.
///
///      Variables (todas opcionales salvo PRIVATE_KEY):
///        ADMIN_ADDRESS        Safe multisig dueño de los contratos (por defecto el deployer; en mainnet defínelo)
///        COMPLIANCE_ADDRESS   comité de compliance (por defecto ADMIN_ADDRESS)
///        GUARDIAN_ADDRESS     multisig de emergencia 5-de-7 (por defecto ADMIN_ADDRESS)
///        TKN_CAP              tope de TKN en wei (1.000.000.000 * 1e18)
///        STAKING_APR_BPS      APR inicial (1250 = 12,5 %)
///        VOTING_DELAY / VOTING_PERIOD / TIMELOCK_DELAY   segundos (1 día / 5 días / 2 días)
///        QUORUM_BPS           400 = 4 %
///        PROPOSAL_THRESHOLD   TKN mínimos en stake para proponer, en wei (100 * 1e18)
///        DEPLOY_FAUCET        true/false (por defecto true salvo mainnets)
///
///      forge script script/DeployEconomy.s.sol --rpc-url sepolia --broadcast
contract DeployEconomy is Script {
    struct Cfg {
        address admin;
        address compliance;
        address guardian;
        uint256 tknCap;
        uint16 aprBps;
        ToKleanGovernance.Params gov;
        bool faucet;
    }

    function run()
        external
        returns (ToKleanToken token, ToKleanStaking staking, ToKleanGovernance gov, TokenFaucet faucet)
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Cfg memory c = _config(deployer);
        uint256 startBlock = block.number;

        vm.startBroadcast(pk);

        token = new ToKleanToken(deployer, c.tknCap);
        staking = new ToKleanStaking(token, deployer, c.aprBps);
        gov = new ToKleanGovernance(staking, deployer, c.gov);

        token.grantRole(token.MINTER_ROLE(), address(staking));
        staking.grantRole(staking.PARAMETERS_ROLE(), address(gov));
        gov.grantRole(gov.COMPLIANCE_ROLE(), c.compliance);
        gov.grantRole(gov.GUARDIAN_ROLE(), c.guardian);

        if (c.faucet) {
            faucet = new TokenFaucet(token, c.admin);
            token.grantRole(token.MINTER_ROLE(), address(faucet));
        }

        if (c.admin != deployer) {
            // El admin (Safe) conserva control y pausa; el deployer se retira de todo.
            token.grantRole(token.DEFAULT_ADMIN_ROLE(), c.admin);
            token.grantRole(token.PAUSER_ROLE(), c.admin);
            staking.grantRole(staking.DEFAULT_ADMIN_ROLE(), c.admin);
            staking.grantRole(staking.PAUSER_ROLE(), c.admin);
            gov.grantRole(gov.DEFAULT_ADMIN_ROLE(), c.admin);

            token.renounceRole(token.PAUSER_ROLE(), deployer);
            token.renounceRole(token.DEFAULT_ADMIN_ROLE(), deployer);
            staking.renounceRole(staking.PAUSER_ROLE(), deployer);
            staking.renounceRole(staking.PARAMETERS_ROLE(), deployer);
            staking.renounceRole(staking.DEFAULT_ADMIN_ROLE(), deployer);
            gov.renounceRole(gov.DEFAULT_ADMIN_ROLE(), deployer);
        }

        vm.stopBroadcast();

        _writeDeployment(token, staking, gov, faucet, startBlock);

        console2.log("ToKleanToken       ", address(token));
        console2.log("ToKleanStaking     ", address(staking));
        console2.log("ToKleanGovernance  ", address(gov));
        console2.log("TokenFaucet        ", address(faucet));
    }

    function _config(address deployer) internal view returns (Cfg memory c) {
        c.admin = vm.envOr("ADMIN_ADDRESS", deployer);
        c.compliance = vm.envOr("COMPLIANCE_ADDRESS", c.admin);
        c.guardian = vm.envOr("GUARDIAN_ADDRESS", c.admin);
        c.tknCap = vm.envOr("TKN_CAP", uint256(1_000_000_000 ether));
        c.aprBps = uint16(vm.envOr("STAKING_APR_BPS", uint256(1250)));
        c.gov = ToKleanGovernance.Params({
            votingDelay: uint48(vm.envOr("VOTING_DELAY", uint256(1 days))),
            votingPeriod: uint48(vm.envOr("VOTING_PERIOD", uint256(5 days))),
            timelockDelay: uint48(vm.envOr("TIMELOCK_DELAY", uint256(2 days))),
            quorumBps: uint16(vm.envOr("QUORUM_BPS", uint256(400))),
            proposalThreshold: vm.envOr("PROPOSAL_THRESHOLD", uint256(100 ether))
        });
        uint256 id = block.chainid;
        bool mainnet =
            id == 1 || id == 137 || id == 10 || id == 42161 || id == 8453 || id == 56 || id == 43114;
        c.faucet = vm.envOr("DEPLOY_FAUCET", !mainnet);
        require(!(mainnet && c.faucet), "DeployEconomy: faucet no permitido en mainnet");
        if (mainnet) {
            require(c.admin != deployer, "DeployEconomy: define ADMIN_ADDRESS (Safe) en mainnet");
        }
    }

    function _writeDeployment(
        ToKleanToken token,
        ToKleanStaking staking,
        ToKleanGovernance gov,
        TokenFaucet faucet,
        uint256 startBlock
    ) internal {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        if (!vm.exists(path)) {
            vm.writeFile(path, string.concat('{"chainId":', vm.toString(block.chainid), "}"));
        }
        vm.writeJson(vm.toString(address(token)), path, ".ToKleanToken");
        vm.writeJson(vm.toString(address(staking)), path, ".ToKleanStaking");
        vm.writeJson(vm.toString(address(gov)), path, ".ToKleanGovernance");
        vm.writeJson(vm.toString(startBlock), path, ".economyStartBlock");
        if (address(faucet) != address(0)) {
            vm.writeJson(vm.toString(address(faucet)), path, ".TokenFaucet");
        }
    }
}
