// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtCollection} from "../src/ArtCollection.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSale} from "../src/ArtifactsSale.sol";
import {ArtifactsAuction} from "../src/ArtifactsAuction.sol";
import {ArtifactsEscrow} from "../src/ArtifactsEscrow.sol";
import {Traits} from "../src/libraries/ArtifactsSeal.sol";
import {MockIMD, MockVRFCoordinator} from "./mocks/Mocks.sol";

abstract contract Fixture is Test {
    address internal constant OWNER = 0xd3e32C1eBEa3a675EffCaAcAf89196948Abd1386;
    address internal constant ARTIST = address(0xA11);
    address internal constant ARTIST_PAYOUT = address(0xA12);
    address internal constant BROKER = address(0xB01);
    address internal constant ALICE = address(0xA1CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ETH = address(0);

    ArtStorage internal artStorage;
    ArtHouse internal house;
    ArtifactsPiece internal pieceImpl;
    ArtifactsFactory internal factory;
    ArtifactsSale internal sale;
    ArtifactsAuction internal auction;
    ArtifactsEscrow internal escrow;
    MockIMD internal imd;
    MockVRFCoordinator internal vrf;
    uint256 internal artifactsCollection;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        imd = new MockIMD();
        vrf = new MockVRFCoordinator();
        Deploy.Deployment memory d = new Deploy().deploy(Deploy.Config({owner: OWNER, imd: address(imd)}));
        artStorage = d.artStorage;
        house = d.house;
        pieceImpl = d.piece;
        factory = d.factory;
        sale = d.sale;
        auction = d.auction;
        escrow = d.escrow;

        vm.startPrank(OWNER);
        artStorage.setHouse(address(house));
        house.approveArtist(ARTIST, "Myles", ARTIST_PAYOUT);
        house.approveBroker(BROKER);
        artifactsCollection = house.createModuleCollection(ARTIST);
        house.approveModule(address(factory), artifactsCollection);
        house.approveModule(address(sale), artifactsCollection);
        house.approveModule(address(auction), artifactsCollection);
        house.approveModule(address(escrow), artifactsCollection);
        factory.setModules(address(sale), address(auction), address(escrow));
        vm.stopPrank();

        vm.deal(ALICE, 1000 ether);
        vm.deal(BOB, 1000 ether);
        vm.deal(BROKER, 10 ether);
    }

    // ---------------------------------------------------------------- helpers

    function traitsFor(uint16 id) internal pure returns (Traits memory) {
        return Traits({title: "DRIFT", palette: "PRISM", colourCount: uint8(2 + id % 3), direction: "HORIZONTAL"});
    }

    function uploadAllPieces() internal {
        vm.startPrank(OWNER);
        for (uint16 i = 1; i <= 256; ++i) {
            factory.setPiece(i, traitsFor(i), abi.encodePacked("ciphertext-", i), keccak256(abi.encodePacked("K", i)));
        }
        factory.lock();
        vm.stopPrank();
    }

    function configureAndOpenSale(uint256 price) internal {
        vm.startPrank(OWNER);
        sale.configureVRF(address(vrf), bytes32(uint256(1)), 7, false);
        sale.setPrice(price);
        sale.openSale();
        vm.stopPrank();
    }

    /// @dev Buys one edition for `buyer`, fulfils the VRF request with `word`, returns the assigned edition.
    function buyAndAssign(address buyer, address broker, uint256 word) internal returns (uint16 edition) {
        uint256 price = sale.price();
        vm.prank(buyer);
        uint256 purchaseId = sale.buy{value: price}(broker);
        ArtifactsSale.Purchase memory p = sale.purchase(purchaseId);
        vrf.fulfill(p.requestId, word);
        edition = sale.purchase(purchaseId).edition;
    }

    /// @dev Full first-claim flow for an assigned piece.
    function claimPiece(uint16 id, address buyer) internal returns (ArtifactsPiece piece) {
        vm.prank(buyer);
        factory.registerViewingKey(keccak256(abi.encodePacked("vk", buyer)));
        vm.prank(OWNER);
        factory.postContentKey(id, abi.encodePacked("wrapped-for-", buyer));
        vm.prank(buyer);
        piece = ArtifactsPiece(factory.claim(id));
    }
}
