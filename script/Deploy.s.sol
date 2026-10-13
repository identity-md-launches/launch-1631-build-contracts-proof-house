// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSale} from "../src/ArtifactsSale.sol";
import {ArtifactsAuction} from "../src/ArtifactsAuction.sol";
import {ArtifactsEscrow} from "../src/ArtifactsEscrow.sol";

/// @notice Reviewable deployment in the launch order. The launch itself is performed by the IMD factory from the
///         built bytecode; this script documents the constructor wiring and lets tests exercise it directly.
contract Deploy is Script {
    struct Config {
        address owner;
        address imd;
    }

    struct Deployment {
        ArtStorage artStorage;
        ArtHouse house;
        ArtifactsPiece piece;
        ArtifactsFactory factory;
        ArtifactsSale sale;
        ArtifactsAuction auction;
        ArtifactsEscrow escrow;
    }

    /// @notice The IMD ERC-20 buyers may pay with.
    address public constant IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;

    function run() external returns (Deployment memory d) {
        Config memory cfg = Config({owner: vm.envAddress("OWNER"), imd: IMD});
        vm.startBroadcast();
        d = deploy(cfg);
        vm.stopBroadcast();
    }

    function deploy(Config memory cfg) public returns (Deployment memory d) {
        d.artStorage = new ArtStorage(cfg.owner);
        d.house = new ArtHouse(cfg.owner, address(d.artStorage), cfg.imd);
        d.piece = new ArtifactsPiece();
        d.factory = new ArtifactsFactory(cfg.owner, address(d.house), address(d.piece));
        d.sale = new ArtifactsSale(cfg.owner, address(d.house), address(d.factory));
        d.auction = new ArtifactsAuction(cfg.owner, address(d.house), address(d.factory));
        d.escrow = new ArtifactsEscrow(address(d.house), address(d.factory));
    }
}
