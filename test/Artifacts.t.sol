// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSale} from "../src/ArtifactsSale.sol";
import {ArtifactsAuction} from "../src/ArtifactsAuction.sol";
import {ArtifactsEscrow} from "../src/ArtifactsEscrow.sol";
import {ArtifactsSeal, Traits} from "../src/libraries/ArtifactsSeal.sol";
import {MockVRFCoordinator} from "./mocks/Mocks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {B64} from "./mocks/B64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract ArtifactsRegistryTest is Fixture {
    function test_setPieceValidationAndLockNeedsAll256() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsFactory.InvalidPieceId.selector);
        factory.setPiece(0, traitsFor(1), "c", bytes32(uint256(1)));
        vm.expectRevert(ArtifactsFactory.InvalidPieceId.selector);
        factory.setPiece(257, traitsFor(1), "c", bytes32(uint256(1)));
        vm.expectRevert(ArtifactsFactory.EmptyCiphertext.selector);
        factory.setPiece(1, traitsFor(1), "", bytes32(uint256(1)));
        vm.expectRevert(ArtifactsFactory.EmptyTraits.selector);
        factory.setPiece(1, Traits("", "PRISM", 2, "VERTICAL"), "c", bytes32(uint256(1)));
        factory.setPiece(1, traitsFor(1), "cipher", bytes32(uint256(1)));
        assertEq(factory.piecesSet(), 1);
        factory.setPiece(1, traitsFor(1), "cipher2", bytes32(uint256(2))); // replace before lock
        assertEq(factory.piecesSet(), 1);
        assertEq(factory.ciphertextBytes(1), "cipher2");
        vm.expectRevert(abi.encodeWithSelector(ArtifactsFactory.PiecesMissing.selector, 1));
        factory.lock();
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        factory.setPiece(2, traitsFor(2), "c", bytes32(0));

        uploadAllPieces();
        assertTrue(factory.locked());
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsFactory.AlreadyLocked.selector);
        factory.setPiece(1, traitsFor(1), "c", bytes32(0));
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsFactory.AlreadyLocked.selector);
        factory.lock();
    }

    function test_modulesSetOnceAndNotConfiguredStateReverts() public {
        ArtifactsFactory fresh = new ArtifactsFactory(OWNER, address(house), address(pieceImpl));
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.ModulesNotSet.selector);
        fresh.assignEdition(1, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.ModulesNotSet.selector);
        fresh.assignSource(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.ModulesNotSet.selector);
        fresh.registerViewingKeyFor(ALICE, bytes32(uint256(1)));
        vm.expectRevert(ArtHouse.NotModule.selector);
        fresh.royaltyReceiver();
        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsFactory.ZeroAddress.selector);
        fresh.setModules(address(0), address(1), address(2));
        fresh.setModules(address(1), address(2), address(3));
        vm.expectRevert(ArtifactsFactory.ModulesAlreadySet.selector);
        fresh.setModules(address(1), address(2), address(3));
        vm.stopPrank();
        assertEq(factory.royaltyReceiver(), ARTIST_PAYOUT);
    }

    function test_assignmentOnlyByItsModuleAfterLock() public {
        vm.prank(address(sale));
        vm.expectRevert(ArtifactsFactory.NotLocked.selector);
        factory.assignEdition(1, ALICE);
        uploadAllPieces();
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.NotSale.selector);
        factory.assignEdition(1, ALICE);
        vm.prank(address(sale));
        vm.expectRevert(ArtifactsFactory.InvalidPieceId.selector);
        factory.assignEdition(256, ALICE);
        vm.prank(address(sale));
        factory.assignEdition(1, ALICE);
        vm.prank(address(sale));
        vm.expectRevert(ArtifactsFactory.AlreadyAssigned.selector);
        factory.assignEdition(1, BOB);
        vm.prank(address(sale));
        vm.expectRevert(ArtifactsFactory.NotAuction.selector);
        factory.assignSource(ALICE);
        vm.prank(address(auction));
        factory.assignSource(ALICE);
        assertEq(factory.assignedTo(256), ALICE);
    }
}

contract ArtifactsSaleTest is Fixture {
    function setUp() public override {
        super.setUp();
        uploadAllPieces();
    }

    function test_saleStartsClosedAndNeedsPriceVrfAndLock() public {
        assertFalse(sale.open());
        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsSale.NoPrice.selector);
        sale.openSale();
        vm.expectRevert(ArtifactsSale.NoPrice.selector);
        sale.setPrice(0);
        sale.setPrice(1 ether);
        vm.expectRevert(ArtifactsSale.VRFNotConfigured.selector);
        sale.openSale();
        vm.expectRevert(ArtifactsSale.ZeroAddress.selector);
        sale.configureVRF(address(0), bytes32(uint256(1)), 1, false);
        sale.configureVRF(address(vrf), bytes32(uint256(1)), 7, true);
        vm.expectRevert(ArtifactsSale.VRFAlreadyConfigured.selector);
        sale.configureVRF(address(vrf), bytes32(uint256(1)), 7, false);
        sale.openSale();
        vm.expectRevert(ArtifactsSale.SaleIsOpen.selector);
        sale.setPrice(2 ether);
        sale.closeSale();
        sale.setPrice(2 ether);
        sale.openSale();
        vm.stopPrank();
        assertEq(sale.price(), 2 ether);
    }

    function test_openSaleNeedsLockedFactory() public {
        ArtifactsFactory fresh = new ArtifactsFactory(OWNER, address(house), address(pieceImpl));
        ArtifactsSale s = new ArtifactsSale(OWNER, address(house), address(fresh));
        vm.startPrank(OWNER);
        s.configureVRF(address(vrf), bytes32(uint256(1)), 7, false);
        s.setPrice(1 ether);
        vm.expectRevert(ArtifactsSale.FactoryNotLocked.selector);
        s.openSale();
        vm.stopPrank();
    }

    function test_buyPaysExactPriceThroughLedgerAndRequestsVRF() public {
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsSale.SaleNotOpen.selector);
        sale.buy{value: 1 ether}(BROKER);
        configureAndOpenSale(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsSale.WrongPayment.selector);
        sale.buy{value: 0.9 ether}(BROKER);
        vm.prank(ALICE);
        uint256 id = sale.buy{value: 1 ether}(BROKER);
        assertEq(id, 1);
        assertEq(address(house).balance, 1 ether);
        assertEq(house.balances(BROKER, ETH), 0.15 ether);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 0.7 ether);
        assertEq(house.balances(address(house), ETH), 0.15 ether);
        ArtifactsSale.Purchase memory p = sale.purchase(1);
        assertEq(p.buyer, ALICE);
        assertEq(p.edition, 0);
        assertEq(p.requestId, 1);
        assertEq(vrf.consumerOf(1), address(sale));
        (bytes32 kh, uint256 sub, uint16 conf, uint32 gas, uint32 words, bytes memory extra) = vrf.lastRequest();
        assertEq(kh, bytes32(uint256(1)));
        assertEq(sub, 7);
        assertEq(conf, 3);
        assertEq(gas, 250_000);
        assertEq(words, 1);
        assertEq(extra, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), false));
    }

    function test_fulfilmentAssignsAndIgnoresStaleOrForeignRequests() public {
        configureAndOpenSale(1 ether);
        vm.prank(ALICE);
        sale.buy{value: 1 ether}(address(0));
        uint256[] memory words = new uint256[](1);
        words[0] = 5;
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsSale.NotCoordinator.selector);
        sale.rawFulfillRandomWords(1, words);
        // unknown request: ignored, nothing assigned
        vm.prank(address(vrf));
        sale.rawFulfillRandomWords(99, words);
        assertEq(sale.assignedCount(), 0);
        vrf.fulfill(1, 5);
        assertEq(sale.purchase(1).edition, 6);
        assertEq(factory.assignedTo(6), ALICE);
        // a second callback for the same request is ignored
        vrf.fulfill(1, 7);
        assertEq(sale.assignedCount(), 1);
        assertEq(factory.assignedTo(8), address(0));
    }

    function test_retryAfterMissingCallbackMakesOldRequestStale() public {
        configureAndOpenSale(1 ether);
        vm.prank(ALICE);
        sale.buy{value: 1 ether}(address(0));
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsSale.TooEarly.selector);
        sale.retryRequest(1);
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsSale.UnknownPurchase.selector);
        sale.retryRequest(2);
        vm.warp(block.timestamp + 1 days);
        vm.prank(OWNER);
        sale.retryRequest(1);
        assertEq(sale.purchase(1).requestId, 2);
        vrf.fulfill(1, 0); // stale
        assertEq(sale.assignedCount(), 0);
        vrf.fulfill(2, 0);
        assertEq(sale.purchase(1).edition, 1);
        vm.warp(block.timestamp + 1 days);
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsSale.AlreadyAssigned.selector);
        sale.retryRequest(1);
    }

    function test_allEditionsAssignedExactlyOnceThenSoldOut() public {
        configureAndOpenSale(0.1 ether);
        bool[256] memory seen;
        for (uint256 i; i < 255; ++i) {
            address buyer = address(uint160(0x10000 + i));
            vm.deal(buyer, 1 ether);
            uint16 e = buyAndAssign(buyer, BROKER, uint256(keccak256(abi.encode(i, "word"))));
            assertTrue(e >= 1 && e <= 255, "edition out of range");
            assertFalse(seen[e], "edition assigned twice");
            seen[e] = true;
            assertEq(factory.assignedTo(e), buyer);
        }
        assertEq(sale.assignedCount(), 255);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsSale.SoldOut.selector);
        sale.buy{value: 0.1 ether}(BROKER);
        assertEq(address(house).balance, 25.5 ether);
    }

    function testFuzz_randomWordAlwaysLandsOnUnassignedEdition(uint256[8] memory words) public {
        configureAndOpenSale(0.1 ether);
        bool[256] memory seen;
        for (uint256 i; i < 8; ++i) {
            address buyer = address(uint160(0x20000 + i));
            vm.deal(buyer, 1 ether);
            uint16 e = buyAndAssign(buyer, address(0), words[i]);
            assertTrue(e >= 1 && e <= 255);
            assertFalse(seen[e]);
            seen[e] = true;
        }
    }
}

contract ArtifactsClaimTest is Fixture {
    function setUp() public override {
        super.setUp();
        uploadAllPieces();
        configureAndOpenSale(1 ether);
    }

    function test_claimFlowDeploysOneTokenPieceContract() public {
        uint16 e = buyAndAssign(ALICE, BROKER, 41); // edition 42
        assertEq(e, 42);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.NoWrappedKey.selector);
        factory.claim(e);
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsFactory.NoViewingKey.selector);
        factory.postContentKey(e, "wrapped");
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsFactory.NotAssignedBuyer.selector);
        factory.postContentKey(43, "wrapped");
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.EmptyKey.selector);
        factory.registerViewingKey(bytes32(0));
        vm.prank(ALICE);
        factory.registerViewingKey(bytes32(uint256(0xA11CE)));
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        factory.postContentKey(e, "wrapped");
        vm.prank(OWNER);
        factory.postContentKey(e, "wrapped-to-alice");
        vm.prank(BOB);
        vm.expectRevert(ArtifactsFactory.NotAssignedBuyer.selector);
        factory.claim(e);

        vm.prank(ALICE);
        ArtifactsPiece piece = ArtifactsPiece(factory.claim(e));
        assertEq(factory.pieceContract(e), address(piece));
        assertEq(piece.ownerOf(e), ALICE);
        assertEq(piece.balanceOf(ALICE), 1);
        assertEq(piece.name(), "ARTIFACTS #042");
        assertEq(piece.symbol(), "ARTIFACTS");
        assertEq(piece.factory(), address(factory));
        assertEq(piece.pieceId(), e);
        assertEq(piece.wrappedKey(), "wrapped-to-alice");
        assertEq(piece.keyHolder(), ALICE);
        assertEq(piece.commitment(), keccak256(abi.encodePacked("K", e)));
        assertEq(piece.ciphertextBytes(), abi.encodePacked("ciphertext-", e));
        assertEq(piece.traits().colourCount, traitsFor(e).colourCount);
        (address receiver, uint256 amount) = piece.royaltyInfo(e, 1 ether);
        assertEq(receiver, ARTIST_PAYOUT);
        assertEq(amount, 0.075 ether);
        assertTrue(piece.supportsInterface(type(IERC2981).interfaceId));
        assertEq(factory.pendingWrappedKey(e), "");

        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.AlreadyClaimed.selector);
        factory.claim(e);
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsFactory.AlreadyClaimed.selector);
        factory.postContentKey(e, "again");
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        piece.initialize(e, BOB, "x");
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        pieceImpl.initialize(1, BOB, "x");
        assertEq(piece.tokenURI(e), factory.tokenURI(e));
    }

    function test_sealTokenURIMatchesReferenceFrame() public view {
        Traits memory t = Traits("DRIFT", "PRISM", 3, "HORIZONTAL");
        string memory svg = ArtifactsSeal.svg(3, t);
        assertEq(
            svg,
            string.concat(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1080 1080" width="1080" height="1080">',
                '<rect width="1080" height="1080" fill="#ffffff"/>',
                '<g fill="#1a1a1a" font-family="Menlo, ui-monospace, monospace" dominant-baseline="middle" letter-spacing="0.5">',
                '<rect x="200" y="220" width="680" height="640" fill="none" stroke="#1a1a1a" stroke-width="1.3"/>',
                '<rect x="203.2" y="223.2" width="673.6" height="633.6" fill="none" stroke="#1a1a1a" stroke-width="1.3"/>',
                '<text x="218.0" y="250.0" font-size="12.5" text-anchor="start" xml:space="preserve">File View Run</text>',
                '<text x="862.0" y="250.0" font-size="12.5" text-anchor="end" xml:space="preserve">DRIFT</text>',
                '<line x1="203.2" y1="266.0" x2="876.8" y2="266.0" stroke="#1a1a1a" stroke-width="1.2"/>',
                '<line x1="203.2" y1="814.0" x2="876.8" y2="814.0" stroke="#1a1a1a" stroke-width="1.2"/>',
                unicode'<text x="218.0" y="833.0" font-size="12.5" text-anchor="start" xml:space="preserve">PRISM · 3C · HORIZONTAL</text>',
                '<text x="862.0" y="833.0" font-size="12.5" text-anchor="end" xml:space="preserve">SEED 003</text>',
                "</g></svg>"
            )
        );
        string memory uri = factory.tokenURI(3);
        string memory json = B64.decodeDataURI(uri, "data:application/json;base64,");
        assertTrue(_contains(json, '"name":"ARTIFACTS #003"'));
        assertTrue(_contains(json, '{"trait_type":"Palette","value":"PRISM"}'));
        assertTrue(_contains(json, '"image":"data:image/svg+xml;base64,'));
        assertTrue(_contains(json, Base64.encode(bytes(ArtifactsSeal.svg(3, traitsFor(3))))));
        assertTrue(_contains(ArtifactsSeal.svg(256, t), unicode"ARTIFACTS ◆ MASTER"));
        assertTrue(_contains(ArtifactsSeal.svg(256, t), unicode"FIDELITY · MAX · 1/1"));
        assertTrue(_contains(ArtifactsSeal.svg(256, t), 'y1="817.0"'));
        assertEq(ArtifactsSeal.tokenName(256), unicode"ARTIFACTS · THE SOURCE");
        assertEq(ArtifactsSeal.tokenName(7), "ARTIFACTS #007");
        assertEq(ArtifactsSeal.tokenName(255), "ARTIFACTS #255");
    }

    function test_plainTransferClearsKeyAndPreviousOwnerRewraps() public {
        uint16 e = buyAndAssign(ALICE, address(0), 0);
        ArtifactsPiece piece = claimPiece(e, ALICE);
        vm.prank(ALICE);
        piece.transferFrom(ALICE, BOB, e);
        assertEq(piece.ownerOf(e), BOB);
        assertEq(piece.wrappedKey(), "");
        assertEq(piece.keyHolder(), BOB);
        assertEq(piece.previousOwner(), ALICE);
        vm.prank(address(0xBAD));
        vm.expectRevert(ArtifactsPiece.NotKeyPoster.selector);
        piece.setWrappedKey("evil");
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsPiece.EmptyKey.selector);
        piece.setWrappedKey("");
        vm.prank(ALICE);
        piece.setWrappedKey("rewrapped-for-bob");
        assertEq(piece.wrappedKey(), "rewrapped-for-bob");
        assertEq(piece.keyHolder(), BOB);
        // the owner may also post for itself
        vm.prank(BOB);
        piece.setWrappedKey("bob-own");
        assertEq(piece.wrappedKey(), "bob-own");
        // a transfer back to the key holder keeps the key
        vm.prank(BOB);
        piece.transferFrom(BOB, ALICE, e);
        assertEq(piece.wrappedKey(), "");
        assertEq(piece.previousOwner(), BOB);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}

contract ArtifactsEscrowTest is Fixture {
    ArtifactsPiece internal piece;
    uint16 internal e;

    function setUp() public override {
        super.setUp();
        uploadAllPieces();
        configureAndOpenSale(1 ether);
        e = buyAndAssign(ALICE, address(0), 9);
        piece = claimPiece(e, ALICE);
    }

    function _listAndBuy() internal {
        vm.prank(ALICE);
        escrow.list(e, 2 ether);
        vm.prank(BOB);
        escrow.buy{value: 2 ether}(e, bytes32(uint256(0xB0B)));
    }

    function test_listingRules() public {
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotPieceOwner.selector);
        escrow.list(e, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NoPrice.selector);
        escrow.list(e, 0);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.UnknownPiece.selector);
        escrow.list(e == 1 ? 2 : 1, 1 ether);
        vm.prank(ALICE);
        escrow.list(e, 1 ether);
        vm.prank(ALICE);
        escrow.list(e, 3 ether);
        assertEq(escrow.listing(e).price, 3 ether);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotSeller.selector);
        escrow.cancelListing(e);
        vm.prank(ALICE);
        escrow.cancelListing(e);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.buy{value: 3 ether}(e, bytes32(uint256(1)));
    }

    function test_buyTakesExactPriceAndHoldsPiece() public {
        vm.prank(ALICE);
        escrow.list(e, 2 ether);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.WrongPayment.selector);
        escrow.buy{value: 1 ether}(e, bytes32(uint256(1)));
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.SellerCannotBuy.selector);
        escrow.buy{value: 2 ether}(e, bytes32(uint256(1)));
        // seller moved the piece away after listing: the stale listing cannot be bought
        vm.prank(ALICE);
        piece.transferFrom(ALICE, address(0xC0), e);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotPieceOwner.selector);
        escrow.buy{value: 2 ether}(e, bytes32(uint256(1)));
        vm.prank(address(0xC0));
        piece.transferFrom(address(0xC0), ALICE, e);
        // back with the seller, but the listing died with the transfer: it must be made again
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.ListingStale.selector);
        escrow.buy{value: 2 ether}(e, bytes32(uint256(1)));
        vm.prank(ALICE);
        escrow.list(e, 2 ether);

        vm.prank(BOB);
        escrow.buy{value: 2 ether}(e, bytes32(uint256(0xB0B)));
        assertEq(piece.ownerOf(e), address(escrow));
        assertEq(factory.viewingKey(BOB), bytes32(uint256(0xB0B)));
        assertEq(escrow.listing(e).buyer, BOB);
        assertEq(address(escrow).balance, 2 ether);
        vm.deal(address(0xD0), 2 ether);
        vm.prank(address(0xD0));
        vm.expectRevert(ArtifactsEscrow.ListingFunded.selector);
        escrow.buy{value: 2 ether}(e, bytes32(uint256(1)));
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NotPieceOwner.selector); // the piece is held in escrow
        escrow.list(e, 5 ether);
    }

    function test_buyerCancelsUntilKeyPostedAndIsRefundedByPull() public {
        _listAndBuy();
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NotBuyer.selector);
        escrow.cancel(e);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.KeyNotPosted.selector);
        escrow.confirm(e);
        vm.prank(BOB);
        escrow.cancel(e);
        assertEq(piece.ownerOf(e), ALICE);
        assertEq(escrow.refunds(BOB), 2 ether);
        assertEq(escrow.listing(e).seller, address(0));
        uint256 before = BOB.balance;
        vm.prank(BOB);
        escrow.withdrawRefund();
        assertEq(BOB.balance - before, 2 ether);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NoRefund.selector);
        escrow.withdrawRefund();
        // seller can re-wrap its own key after the piece came back
        vm.prank(ALICE);
        piece.setWrappedKey("alice-again");
        assertEq(piece.keyHolder(), ALICE);
    }

    function test_confirmReleasesPaymentThroughLedgerWithRoyalty() public {
        _listAndBuy();
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotSeller.selector);
        escrow.postKey(e, "k");
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.EmptyKey.selector);
        escrow.postKey(e, "");
        vm.prank(ALICE);
        escrow.postKey(e, "rewrapped-for-bob");
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.KeyAlreadyPosted.selector);
        escrow.postKey(e, "again");
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.KeyAlreadyPosted.selector);
        escrow.cancel(e);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NotBuyer.selector);
        escrow.confirm(e);
        uint256 artistBefore = house.balances(ARTIST_PAYOUT, ETH);
        vm.prank(BOB);
        escrow.confirm(e);
        assertEq(piece.ownerOf(e), BOB);
        assertEq(piece.wrappedKey(), "rewrapped-for-bob");
        assertEq(piece.keyHolder(), BOB);
        assertEq(house.balances(ARTIST_PAYOUT, ETH) - artistBefore, 0.15 ether);
        assertEq(house.balances(ALICE, ETH), 1.85 ether);
        assertEq(address(escrow).balance, 0);
        vm.prank(ALICE);
        house.withdraw(ETH);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.confirm(e);
    }

    function test_releaseAfter72Hours() public {
        _listAndBuy();
        vm.expectRevert(ArtifactsEscrow.KeyNotPosted.selector);
        escrow.release(e);
        vm.prank(ALICE);
        escrow.postKey(e, "rewrapped");
        vm.warp(block.timestamp + 72 hours - 1);
        vm.expectRevert(ArtifactsEscrow.TooEarly.selector);
        escrow.release(e);
        vm.warp(block.timestamp + 1);
        escrow.release(e);
        assertEq(piece.ownerOf(e), BOB);
        assertEq(piece.wrappedKey(), "rewrapped");
        assertEq(house.balances(ALICE, ETH), 1.85 ether);
    }

    function test_escrowOperatorRightsAreLimitedToTheEscrow() public {
        assertTrue(piece.isApprovedForAll(ALICE, address(escrow)));
        assertFalse(piece.isApprovedForAll(ALICE, address(factory)));
        vm.prank(BOB);
        vm.expectRevert();
        piece.transferFrom(ALICE, BOB, e);
    }

    function test_cancelRestoresSellerWrappedKey() public {
        bytes memory before = piece.wrappedKey();
        assertGt(before.length, 0);
        _listAndBuy();
        assertEq(piece.wrappedKey(), "");
        vm.prank(BOB);
        escrow.cancel(e);
        assertEq(piece.ownerOf(e), ALICE);
        assertEq(piece.wrappedKey(), before);
        assertEq(piece.keyHolder(), ALICE);
        // a seller that had no key (after a plain transfer) gets none back, and cancel still succeeds
        vm.prank(ALICE);
        piece.transferFrom(ALICE, address(0xC0), e);
        vm.prank(address(0xC0));
        escrow.list(e, 1 ether);
        vm.prank(BOB);
        escrow.buy{value: 1 ether}(e, bytes32(uint256(2)));
        vm.prank(BOB);
        escrow.cancel(e);
        assertEq(piece.ownerOf(e), address(0xC0));
        assertEq(piece.wrappedKey(), "");
    }

    function test_releaseWhenModuleRevokedHoldsPriceForSellerAndStillDelivers() public {
        _listAndBuy();
        vm.prank(ALICE);
        escrow.postKey(e, "rewrapped");
        vm.prank(OWNER);
        house.revokeModule(address(escrow));
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.KeyAlreadyPosted.selector);
        escrow.cancel(e);
        uint256 artistBefore = house.balances(ARTIST_PAYOUT, ETH);
        vm.prank(BOB);
        escrow.confirm(e);
        assertEq(piece.ownerOf(e), BOB);
        assertEq(piece.wrappedKey(), "rewrapped");
        assertEq(escrow.refunds(ALICE), 2 ether);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), artistBefore);
        assertEq(house.balances(ALICE, ETH), 0);
        uint256 bal = ALICE.balance;
        vm.prank(ALICE);
        escrow.withdrawRefund();
        assertEq(ALICE.balance - bal, 2 ether);
        assertEq(address(escrow).balance, 0);
    }

    function test_previousOwnerCannotOverwriteAPostedKey() public {
        vm.prank(ALICE);
        piece.transferFrom(ALICE, BOB, e);
        vm.prank(BOB);
        piece.setWrappedKey("bob-good");
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsPiece.NotKeyPoster.selector);
        piece.setWrappedKey("garbage");
        assertEq(piece.wrappedKey(), "bob-good");
        // the previous owner may post first, once, and the holder may still replace it afterwards
        vm.prank(BOB);
        piece.transferFrom(BOB, address(0xC0), e);
        vm.prank(BOB);
        piece.setWrappedKey("for-c0");
        vm.prank(BOB);
        vm.expectRevert(ArtifactsPiece.NotKeyPoster.selector);
        piece.setWrappedKey("for-c0-again");
        vm.prank(address(0xC0));
        piece.setWrappedKey("c0-own");
        assertEq(piece.wrappedKey(), "c0-own");
        assertEq(piece.transferCount(), 2);
    }

    function test_royaltyInfoSurvivesFactoryModuleRevocation() public {
        (address receiver, uint256 amount) = piece.royaltyInfo(e, 1 ether);
        assertEq(receiver, ARTIST_PAYOUT);
        assertEq(amount, 0.075 ether);
        vm.prank(OWNER);
        house.revokeModule(address(factory));
        (receiver,) = piece.royaltyInfo(e, 1 ether);
        assertEq(receiver, ARTIST_PAYOUT);
        assertFalse(house.isModule(address(factory)));
        assertEq(house.moduleCollection(address(factory)), artifactsCollection);
    }
}

contract ArtifactsWiringTest is Fixture {
    ArtifactsFactory internal f2;
    ArtifactsSale internal s2;
    ArtifactsAuction internal a2;

    function setUp() public override {
        super.setUp();
        f2 = new ArtifactsFactory(OWNER, address(house), address(pieceImpl));
        s2 = new ArtifactsSale(OWNER, address(house), address(f2));
        a2 = new ArtifactsAuction(OWNER, address(house), address(f2));
        vm.startPrank(OWNER);
        house.approveModule(address(s2), artifactsCollection);
        house.approveModule(address(a2), artifactsCollection);
        for (uint16 i = 1; i <= 256; ++i) {
            f2.setPiece(i, traitsFor(i), abi.encodePacked("c", i), keccak256(abi.encodePacked("K", i)));
        }
        f2.lock();
        s2.configureVRF(address(vrf), bytes32(uint256(1)), 7, false);
        s2.setPrice(1 ether);
        vm.stopPrank();
    }

    function test_openSaleAndConfigureNeedTheFactoryToNameThem() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsSale.FactoryNotWired.selector);
        s2.openSale();
        vm.expectRevert(ArtifactsAuction.FactoryNotWired.selector);
        a2.configure(1 ether, uint64(block.timestamp + 1 days));
        // wired to other contracts: still refused
        f2.setModules(address(0xdead), address(0xdead), address(0xdead));
        vm.expectRevert(ArtifactsSale.FactoryNotWired.selector);
        s2.openSale();
        vm.expectRevert(ArtifactsAuction.FactoryNotWired.selector);
        a2.configure(1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertFalse(s2.open());
    }

    function test_correctWiringOpens() public {
        vm.startPrank(OWNER);
        f2.setModules(address(s2), address(a2), address(escrow));
        s2.openSale();
        a2.configure(1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertTrue(s2.open());
        assertEq(a2.reserve(), 1 ether);
    }
}

contract ArtifactsAuctionTest is Fixture {
    function setUp() public override {
        super.setUp();
        uploadAllPieces();
    }

    function _configure() internal {
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 days));
    }

    function test_configureRules() public {
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsAuction.NotConfigured.selector);
        auction.bid{value: 1 ether}();
        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsAuction.BelowReserve.selector);
        auction.configure(0, uint64(block.timestamp + 1));
        vm.expectRevert(ArtifactsAuction.BadEndTime.selector);
        auction.configure(1 ether, uint64(block.timestamp));
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        auction.configure(1 ether, uint64(block.timestamp + 1 days));
        _configure();
        vm.prank(ALICE);
        auction.bid{value: 1 ether}();
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsAuction.AuctionStarted.selector);
        auction.configure(2 ether, uint64(block.timestamp + 2 days));
    }

    function test_dustBidsStillNeedAStrictIncrement() public {
        vm.prank(OWNER);
        auction.configure(1, uint64(block.timestamp + 1 days));
        vm.prank(ALICE);
        auction.bid{value: 19}();
        assertEq(auction.minimumBid(), 20);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ArtifactsAuction.BelowIncrement.selector, 20));
        auction.bid{value: 19}();
        vm.prank(BOB);
        auction.bid{value: 20}();
        assertEq(auction.highBidder(), BOB);
        assertEq(auction.minimumBid(), 21);
    }

    function test_settleWhileRevokedHoldsProceedsUntilForwarded() public {
        _configure();
        vm.prank(BOB);
        auction.bid{value: 4 ether}();
        vm.warp(auction.endTime());
        vm.prank(OWNER);
        house.revokeModule(address(auction));
        auction.settle();
        assertEq(factory.assignedTo(256), BOB);
        assertEq(auction.heldProceeds(), 4 ether);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 0);
        vm.expectRevert(ArtHouse.NotModule.selector);
        auction.forwardProceeds();
        vm.prank(OWNER);
        house.approveModule(address(auction), artifactsCollection);
        auction.forwardProceeds();
        assertEq(auction.heldProceeds(), 0);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 2.8 ether);
        assertEq(house.balances(address(house), ETH), 1.2 ether);
        vm.expectRevert(ArtifactsAuction.NothingHeld.selector);
        auction.forwardProceeds();
    }

    function test_configureNeedsLockedFactory() public {
        ArtifactsFactory fresh = new ArtifactsFactory(OWNER, address(house), address(pieceImpl));
        ArtifactsAuction a = new ArtifactsAuction(OWNER, address(house), address(fresh));
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsAuction.FactoryNotLocked.selector);
        a.configure(1 ether, uint64(block.timestamp + 1 days));
    }

    function test_bidsMustBeatReserveAndFivePercentIncrement() public {
        _configure();
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsAuction.BelowReserve.selector);
        auction.bid{value: 0.5 ether}();
        vm.prank(ALICE);
        auction.bid{value: 1 ether}();
        assertEq(auction.minimumBid(), 1.05 ether);
        // the 5% increment rounds up, so a bid never merely equals the high bid
        assertEq(auction.minimumBid() - auction.highBid(), 0.05 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ArtifactsAuction.BelowIncrement.selector, 1.05 ether));
        auction.bid{value: 1 ether}();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ArtifactsAuction.BelowIncrement.selector, 1.05 ether));
        auction.bid{value: 1.04 ether}();
        vm.prank(BOB);
        auction.bid{value: 1.05 ether}();
        assertEq(auction.highBidder(), BOB);
        assertEq(auction.refunds(ALICE), 1 ether);
        vm.prank(ALICE);
        auction.bid{value: 2 ether}();
        assertEq(auction.refunds(BOB), 1.05 ether);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        auction.withdrawRefund();
        assertEq(ALICE.balance - before, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsAuction.NoRefund.selector);
        auction.withdrawRefund();
        assertEq(address(auction).balance, 3.05 ether);
    }

    function test_lateBidExtendsEndByTenMinutes() public {
        _configure();
        uint64 end = auction.endTime();
        vm.warp(end - 11 minutes);
        vm.prank(ALICE);
        auction.bid{value: 1 ether}();
        assertEq(auction.endTime(), end);
        vm.warp(end - 5 minutes);
        vm.prank(BOB);
        auction.bid{value: 1.1 ether}();
        assertEq(auction.endTime(), uint64(block.timestamp) + 10 minutes);
        vm.warp(auction.endTime());
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsAuction.Ended.selector);
        auction.bid{value: 2 ether}();
    }

    function test_settleAssignsSourceAndPaysLedger() public {
        _configure();
        vm.expectRevert(ArtifactsAuction.NotEnded.selector);
        auction.settle();
        vm.warp(auction.endTime());
        vm.expectRevert(ArtifactsAuction.NoBids.selector);
        auction.settle();
        // nothing sold: curator may run it again
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 days));
        vm.prank(ALICE);
        auction.bid{value: 1 ether}();
        vm.prank(BOB);
        auction.bid{value: 4 ether}();
        vm.warp(auction.endTime());
        auction.settle();
        assertTrue(auction.settled());
        assertEq(factory.assignedTo(256), BOB);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 2.8 ether);
        assertEq(house.balances(address(house), ETH), 1.2 ether);
        assertEq(address(auction).balance, 1 ether); // Alice's refund still pulls
        vm.expectRevert(ArtifactsAuction.AlreadySettled.selector);
        auction.settle();
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsAuction.AuctionStarted.selector);
        auction.configure(1 ether, uint64(block.timestamp + 1 days));

        ArtifactsPiece source = claimPiece(256, BOB);
        assertEq(source.name(), unicode"ARTIFACTS · THE SOURCE");
        assertEq(source.ownerOf(256), BOB);
        vm.prank(ALICE);
        auction.withdrawRefund();
        assertEq(address(auction).balance, 0);
    }
}
