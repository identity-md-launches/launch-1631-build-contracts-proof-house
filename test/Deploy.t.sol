// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsSale} from "../src/ArtifactsSale.sol";
import {ArtifactsAuction} from "../src/ArtifactsAuction.sol";

contract DeployTest is Test {
    address internal constant OWNER = 0xd3e32C1eBEa3a675EffCaAcAf89196948Abd1386;

    function test_deployWiresOwnersAndReferencesWithoutPostCalls() public {
        Deploy script = new Deploy();
        Deploy.Deployment memory d = script.deploy(Deploy.Config({owner: OWNER, imd: script.IMD()}));
        assertEq(d.artStorage.owner(), OWNER);
        assertEq(d.house.owner(), OWNER);
        assertEq(d.factory.owner(), OWNER);
        assertEq(d.sale.owner(), OWNER);
        assertEq(d.auction.owner(), OWNER);
        assertEq(address(d.house.artStorage()), address(d.artStorage));
        assertEq(address(d.house.imd()), script.IMD());
        assertGt(d.house.collectionImplementation().code.length, 0);
        assertEq(address(d.factory.house()), address(d.house));
        assertEq(d.factory.pieceImplementation(), address(d.piece));
        assertEq(address(d.sale.factory()), address(d.factory));
        assertEq(address(d.auction.factory()), address(d.factory));
        assertEq(address(d.escrow.factory()), address(d.factory));
        assertEq(address(d.escrow.house()), address(d.house));
        // nothing is wired until the owner acts
        assertEq(d.artStorage.house(), address(0));
        assertEq(d.factory.sale(), address(0));
        assertEq(d.sale.vrfCoordinator(), address(0));
        assertFalse(d.factory.locked());
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        d.piece.initialize(1, OWNER, "x");
    }

    function test_constructorsRejectZeroReferences() public {
        vm.expectRevert(ArtHouse.ZeroAddress.selector);
        new ArtHouse(OWNER, address(0), address(1));
        vm.expectRevert(ArtifactsFactory.ZeroAddress.selector);
        new ArtifactsFactory(OWNER, address(0), address(1));
        vm.expectRevert(ArtifactsSale.ZeroAddress.selector);
        new ArtifactsSale(OWNER, address(1), address(0));
        vm.expectRevert(ArtifactsAuction.ZeroAddress.selector);
        new ArtifactsAuction(OWNER, address(0), address(1));
    }
}
