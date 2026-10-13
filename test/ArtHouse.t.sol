// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtCollection} from "../src/ArtCollection.sol";
import {HouseOwnable} from "../src/HouseOwnable.sol";
import {FeeToken, Rejector, Reenterer} from "./mocks/Mocks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {B64} from "./mocks/B64.sol";

contract ArtHouseTest is Fixture {
    uint256 internal col;
    ArtCollection internal token;
    bytes internal constant SVG = '<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>';

    function setUp() public override {
        super.setUp();
        vm.prank(OWNER);
        (col, token) = _create("Later Works", "LATER");
    }

    function _create(string memory n, string memory s) internal returns (uint256 id, ArtCollection t) {
        address tk;
        (id, tk) = house.createCollection(ARTIST, n, s);
        t = ArtCollection(tk);
    }

    function _uploadAndSeal(uint256 collection, uint256 count) internal {
        vm.startPrank(ARTIST);
        for (uint256 i = 1; i <= count; ++i) {
            house.registerPiece(collection, i, keccak256(SVG), "Piece", "A plain SVG piece");
            house.uploadChunk(collection, i, 0, SVG);
            house.finalizePiece(collection, i);
        }
        vm.stopPrank();
        vm.prank(OWNER);
        house.seal(collection);
    }

    function _openEth(uint256 price) internal {
        vm.startPrank(OWNER);
        house.setPrices(col, uint128(price), 0);
        house.openSale(col);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- ownership

    function test_ownershipIsTwoStepAndRenounceDisabled() public {
        assertEq(house.owner(), OWNER);
        vm.prank(OWNER);
        house.transferOwnership(ALICE);
        assertEq(house.owner(), OWNER);
        vm.prank(ALICE);
        house.acceptOwnership();
        assertEq(house.owner(), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(HouseOwnable.RenounceDisabled.selector);
        house.renounceOwnership();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        house.renounceOwnership();
    }

    function test_onlyCuratorManagesRoles() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        house.approveArtist(ALICE, "x", ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        house.approveBroker(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        house.createCollection(ARTIST, "n", "s");
    }

    function test_artistChangesPayoutOnlyWhenApproved() public {
        vm.prank(ARTIST);
        house.setPayout(address(0xA13));
        assertEq(house.artist(ARTIST).payout, address(0xA13));
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.setPayout(ALICE);
        vm.prank(OWNER);
        house.revokeArtist(ARTIST);
        vm.prank(ARTIST);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.setPayout(ARTIST);
        vm.prank(OWNER);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.createCollection(ARTIST, "n", "s");
    }

    // ---------------------------------------------------------------- storage

    function test_storageWritesOnlyFromHouseAndSetHouseOnce() public {
        vm.prank(OWNER);
        vm.expectRevert(ArtStorage.HouseAlreadySet.selector);
        artStorage.setHouse(ALICE);
        vm.prank(OWNER);
        vm.expectRevert(ArtStorage.NotHouse.selector);
        artStorage.registerPiece(col, 1, bytes32(0), "t", "d");
        vm.prank(ALICE);
        vm.expectRevert(ArtStorage.NotHouse.selector);
        artStorage.uploadChunk(col, 1, 0, "x");
    }

    function test_pieceIdsAndChunkIndexesMustBeNext() public {
        vm.startPrank(ARTIST);
        vm.expectRevert(abi.encodeWithSelector(ArtStorage.PieceIdNotNext.selector, 1));
        house.registerPiece(col, 2, keccak256(SVG), "t", "d");
        house.registerPiece(col, 1, keccak256(SVG), "t", "d");
        vm.expectRevert(abi.encodeWithSelector(ArtStorage.ChunkIndexNotNext.selector, 0));
        house.uploadChunk(col, 1, 1, SVG);
        vm.expectRevert(ArtStorage.UnknownPiece.selector);
        house.uploadChunk(col, 2, 0, SVG);
        house.uploadChunk(col, 1, 0, SVG);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NotCuratorOrArtist.selector);
        house.uploadChunk(col, 1, 1, SVG);
    }

    function test_finalizeChecksContentHashAndClearResets() public {
        vm.startPrank(ARTIST);
        house.registerPiece(col, 1, keccak256(SVG), "t", "d");
        house.uploadChunk(col, 1, 0, "wrong");
        vm.expectRevert(
            abi.encodeWithSelector(ArtStorage.ContentHashMismatch.selector, keccak256(SVG), keccak256("wrong"))
        );
        house.finalizePiece(col, 1);
        vm.stopPrank();
        vm.prank(ARTIST);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ARTIST));
        house.clearPiece(col, 1);
        vm.prank(OWNER);
        house.clearPiece(col, 1);
        // chunks arrive in two parts and concatenate
        bytes memory first = new bytes(10);
        bytes memory second = new bytes(SVG.length - 10);
        for (uint256 i; i < SVG.length; ++i) {
            if (i < 10) first[i] = SVG[i];
            else second[i - 10] = SVG[i];
        }
        vm.startPrank(ARTIST);
        house.uploadChunk(col, 1, 0, first);
        house.uploadChunk(col, 1, 1, second);
        house.finalizePiece(col, 1);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.uploadChunk(col, 1, 2, "more");
        vm.stopPrank();
        assertEq(artStorage.pieceBytes(col, 1), SVG);
        vm.prank(OWNER);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.clearPiece(col, 1);
    }

    function test_piecesOver100KBRejected() public {
        vm.startPrank(ARTIST);
        house.registerPiece(col, 1, bytes32(0), "t", "d");
        bytes memory big = new bytes(24_000);
        house.uploadChunk(col, 1, 0, big);
        house.uploadChunk(col, 1, 1, big);
        house.uploadChunk(col, 1, 2, big);
        house.uploadChunk(col, 1, 3, big);
        vm.expectRevert(ArtStorage.PieceTooLarge.selector);
        house.uploadChunk(col, 1, 4, new bytes(6401));
        house.uploadChunk(col, 1, 4, new bytes(6400));
        vm.stopPrank();
    }

    function test_sealNeedsEveryPieceFinalized() public {
        vm.startPrank(ARTIST);
        house.registerPiece(col, 1, keccak256(SVG), "t", "d");
        house.uploadChunk(col, 1, 0, SVG);
        house.finalizePiece(col, 1);
        house.registerPiece(col, 2, keccak256(SVG), "t", "d");
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ArtStorage.PieceNotFinalized.selector, 2));
        house.seal(col);
        vm.prank(OWNER);
        vm.expectRevert(ArtHouse.NotSealed.selector);
        house.openSale(col);
    }

    // ---------------------------------------------------------------- sales

    function test_openSaleNeedsSealAndPrice() public {
        _uploadAndSeal(col, 1);
        vm.startPrank(OWNER);
        vm.expectRevert(ArtHouse.NoPrice.selector);
        house.openSale(col);
        house.setPrices(col, 1 ether, 0);
        house.openSale(col);
        vm.expectRevert(ArtHouse.SaleOpen.selector);
        house.setPrices(col, 2 ether, 0);
        house.closeSale(col);
        house.setPrices(col, 2 ether, 0);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.SaleNotOpen.selector);
        house.mint{value: 2 ether}(col, 1, address(0));
    }

    function test_mintSplitsAndEveryPartyWithdraws() public {
        _uploadAndSeal(col, 2);
        _openEth(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.WrongPayment.selector);
        house.mint{value: 0.5 ether}(col, 1, BROKER);

        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, BROKER);
        assertEq(token.ownerOf(1), ALICE);
        assertEq(house.balances(BROKER, ETH), 0.15 ether);
        assertEq(house.balances(address(house), ETH), 0.15 ether);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 0.7 ether);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        house.mint{value: 1 ether}(col, 1, BROKER);

        uint256 before = BROKER.balance;
        vm.prank(BROKER);
        house.withdraw(ETH);
        assertEq(BROKER.balance - before, 0.15 ether);
        vm.prank(BROKER);
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.withdraw(ETH);

        before = ARTIST_PAYOUT.balance;
        vm.prank(ARTIST_PAYOUT);
        house.withdraw(ETH);
        assertEq(ARTIST_PAYOUT.balance - before, 0.7 ether);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        house.withdrawHouse(ETH);
        before = OWNER.balance;
        vm.prank(OWNER);
        house.withdrawHouse(ETH);
        assertEq(OWNER.balance - before, 0.15 ether);
        assertEq(address(house).balance, 0);
    }

    function test_brokerShareGoesToHouseWhenUnapprovedOrBuyer() public {
        _uploadAndSeal(col, 3);
        _openEth(1 ether);
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, ALICE); // buyer as broker
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 2, BOB); // unapproved
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 3, address(0)); // none
        assertEq(house.balances(ALICE, ETH), 0);
        assertEq(house.balances(BOB, ETH), 0);
        assertEq(house.balances(address(house), ETH), 0.9 ether);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 2.1 ether);
    }

    function test_customSplitAndRoundingToHouse() public {
        _uploadAndSeal(col, 1);
        vm.prank(OWNER);
        vm.expectRevert(ArtHouse.BadSplit.selector);
        house.setSplit(col, 1000, 1000, 1000);
        vm.prank(OWNER);
        house.setSplit(col, 3333, 3333, 3334);
        _openEth(1001);
        vm.prank(ALICE);
        house.mint{value: 1001}(col, 1, BROKER);
        uint256 b = house.balances(BROKER, ETH);
        uint256 a = house.balances(ARTIST_PAYOUT, ETH);
        uint256 h = house.balances(address(house), ETH);
        assertEq(b, uint256(1001) * 3333 / 10_000);
        assertEq(a, uint256(1001) * 3334 / 10_000);
        assertEq(b + a + h, 1001);
        assertGe(h, uint256(1001) * 3333 / 10_000);
    }

    function testFuzz_splitConservesEveryWei(uint96 amount, uint16 brokerBps, uint16 houseBps) public {
        amount = uint96(bound(amount, 1, 1000 ether));
        brokerBps = uint16(bound(brokerBps, 0, 10_000));
        houseBps = uint16(bound(houseBps, 0, 10_000 - brokerBps));
        uint16 artistBps = 10_000 - brokerBps - houseBps;
        _uploadAndSeal(col, 1);
        vm.prank(OWNER);
        house.setSplit(col, brokerBps, houseBps, artistBps);
        _openEth(amount);
        vm.prank(ALICE);
        house.mint{value: amount}(col, 1, BROKER);
        assertEq(
            house.balances(BROKER, ETH) + house.balances(ARTIST_PAYOUT, ETH) + house.balances(address(house), ETH),
            amount
        );
        assertEq(address(house).balance, amount);
    }

    function test_mintWithIMDPullsExactPrice() public {
        _uploadAndSeal(col, 2);
        vm.startPrank(OWNER);
        house.setPrices(col, 0, 500e18);
        house.openSale(col);
        vm.stopPrank();
        imd.mint(ALICE, 1000e18);
        vm.prank(ALICE);
        imd.approve(address(house), 1000e18);

        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mintWithIMD(col, 1, BROKER, 400e18);
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NoPrice.selector);
        house.mint{value: 1}(col, 1, BROKER);

        vm.prank(ALICE);
        house.mintWithIMD(col, 1, BROKER, 500e18);
        assertEq(token.ownerOf(1), ALICE);
        assertEq(imd.balanceOf(address(house)), 500e18);
        assertEq(house.balances(BROKER, address(imd)), 75e18);
        assertEq(house.balances(ARTIST_PAYOUT, address(imd)), 350e18);
        assertEq(house.balances(address(house), address(imd)), 75e18);
        vm.prank(ARTIST_PAYOUT);
        house.withdraw(address(imd));
        assertEq(imd.balanceOf(ARTIST_PAYOUT), 350e18);
        vm.prank(OWNER);
        house.withdrawHouse(address(imd));
        assertEq(imd.balanceOf(OWNER), 75e18);
    }

    function test_mintWithIMDRejectsFeeOnTransfer() public {
        FeeToken fee = new FeeToken();
        ArtStorage st = new ArtStorage(OWNER);
        ArtHouse h = new ArtHouse(OWNER, address(st), address(fee));
        vm.startPrank(OWNER);
        st.setHouse(address(h));
        h.approveArtist(ARTIST, "a", ARTIST_PAYOUT);
        (uint256 c,) = h.createCollection(ARTIST, "n", "s");
        h.registerPiece(c, 1, keccak256(SVG), "t", "d");
        h.uploadChunk(c, 1, 0, SVG);
        h.finalizePiece(c, 1);
        h.seal(c);
        h.setPrices(c, 0, 100e18);
        h.openSale(c);
        vm.stopPrank();
        fee.mint(ALICE, 1000e18);
        vm.prank(ALICE);
        fee.approve(address(h), 1000e18);
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.TransferAmountMismatch.selector);
        h.mintWithIMD(c, 1, address(0), 100e18);
    }

    function test_tokenURIIsOnChainBase64JSONWithSVG() public {
        _uploadAndSeal(col, 1);
        _openEth(1 ether);
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, address(0));
        string memory uri = token.tokenURI(1);
        string memory json = B64.decodeDataURI(uri, "data:application/json;base64,");
        assertEq(
            json,
            string.concat(
                '{"name":"Piece","description":"A plain SVG piece","image":"data:image/svg+xml;base64,',
                Base64.encode(SVG),
                '"}'
            )
        );
        assertEq(token.name(), "Later Works");
        assertEq(token.symbol(), "LATER");
        assertEq(token.maxSupply(), 1);
        (address receiver, uint256 amount) = token.royaltyInfo(1, 10 ether);
        assertEq(receiver, ARTIST_PAYOUT);
        assertEq(amount, 0.75 ether);
        assertTrue(token.supportsInterface(type(IERC2981).interfaceId));
        vm.expectRevert();
        token.tokenURI(2);
    }

    function test_collectionImplementationAndCloneCannotBeReinitializedOrMintedDirectly() public {
        ArtCollection impl = ArtCollection(house.collectionImplementation());
        vm.expectRevert(ArtCollection.AlreadyInitialized.selector);
        impl.initialize(ALICE, ALICE, 1, "x", "y");
        vm.expectRevert(ArtCollection.AlreadyInitialized.selector);
        token.initialize(ALICE, ALICE, 1, "x", "y");
        vm.prank(ALICE);
        vm.expectRevert(ArtCollection.NotHouse.selector);
        token.mint(ALICE, 1);
    }

    function test_recordSaleOnlyFromApprovedModules() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(ArtHouse.NotModule.selector);
        house.recordSale{value: 1 ether}(ALICE, address(0));
        vm.expectRevert(ArtHouse.NotModule.selector);
        house.recordResale{value: 1 ether}(ALICE);
        vm.prank(OWNER);
        house.revokeModule(address(sale));
        vm.deal(address(sale), 1 ether);
        vm.prank(address(sale));
        vm.expectRevert(ArtHouse.NotModule.selector);
        house.recordSale{value: 1 ether}(ALICE, address(0));
    }

    function test_withdrawIsNonReentrantAndRevertsForRejectingReceivers() public {
        _uploadAndSeal(col, 1);
        _openEth(1 ether);
        Reenterer r = new Reenterer(address(house));
        vm.prank(OWNER);
        house.approveBroker(address(r));
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, address(r));
        vm.prank(address(r));
        house.withdraw(ETH);
        assertFalse(r.reentered());
        assertEq(address(r).balance, 0.15 ether);

        Rejector rej = new Rejector();
        vm.prank(ARTIST);
        house.setPayout(address(rej));
        vm.prank(OWNER);
        (uint256 c2,) = _create("Two", "TWO");
        _uploadAndSeal(c2, 1);
        vm.startPrank(OWNER);
        house.setPrices(c2, 1 ether, 0);
        house.openSale(c2);
        vm.stopPrank();
        vm.prank(ALICE);
        house.mint{value: 1 ether}(c2, 1, address(0));
        vm.prank(address(rej));
        vm.expectRevert(ArtHouse.EthTransferFailed.selector);
        house.withdraw(ETH);
        assertEq(house.balances(address(rej), ETH), 0.7 ether);
    }

    // ---------------------------------------------------------------- submissions

    function test_submissionsAcceptedOrRejectedOnce() public {
        vm.prank(ALICE);
        uint256 id = house.submit(keccak256("art"), "ipfs://preview");
        assertEq(id, 1);
        ArtHouse.Submission memory s = house.submission(1);
        assertEq(s.submitter, ALICE);
        assertEq(s.previewURI, "ipfs://preview");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        house.acceptSubmission(1);
        vm.startPrank(OWNER);
        vm.expectRevert(ArtHouse.UnknownSubmission.selector);
        house.acceptSubmission(2);
        house.acceptSubmission(1);
        vm.expectRevert(ArtHouse.SubmissionDecidedAlready.selector);
        house.rejectSubmission(1);
        vm.stopPrank();
        assertEq(uint8(house.submission(1).status), uint8(ArtHouse.SubmissionStatus.Accepted));
        vm.prank(BOB);
        house.submit(keccak256("b"), "x");
        vm.prank(OWNER);
        house.rejectSubmission(2);
        assertEq(uint8(house.submission(2).status), uint8(ArtHouse.SubmissionStatus.Rejected));
    }

    // ---------------------------------------------------------------- revision: storage and access repairs

    function test_readCostIsLinearIn100KBOfSmallChunks() public {
        bytes memory chunk = new bytes(1024);
        for (uint256 i; i < chunk.length; ++i) {
            chunk[i] = bytes1(uint8(65 + i % 26));
        }
        bytes memory all;
        for (uint256 i; i < 100; ++i) {
            all = bytes.concat(all, chunk);
        }
        vm.startPrank(ARTIST);
        house.registerPiece(col, 1, keccak256(all), "t", "d");
        for (uint256 i; i < 100; ++i) {
            house.uploadChunk(col, 1, i, chunk);
        }
        (bool finalized,) = address(house).call{gas: 30_000_000}(abi.encodeCall(ArtHouse.finalizePiece, (col, 1)));
        vm.stopPrank();
        assertTrue(finalized);
        assertEq(artStorage.pieceBytes(col, 1), all);
        vm.prank(OWNER);
        house.seal(col);
        _openEth(1 ether);
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, address(0));
        (bool rendered,) = address(token).staticcall{gas: 50_000_000}(abi.encodeCall(token.tokenURI, (1)));
        assertTrue(rendered);
    }

    function test_chunksAboveOneSstore2ContractAreRejected() public {
        vm.startPrank(ARTIST);
        house.registerPiece(col, 1, keccak256("x"), "t", "d");
        vm.expectRevert(ArtStorage.ChunkTooLarge.selector);
        house.uploadChunk(col, 1, 0, new bytes(24_576));
        vm.expectRevert(ArtStorage.ChunkTooLarge.selector);
        house.uploadChunk(col, 1, 0, new bytes(65_535));
        bytes memory max = new bytes(24_575);
        house.uploadChunk(col, 1, 0, max);
        vm.stopPrank();
        assertEq(artStorage.pieceBytes(col, 1).length, 24_575);
        assertEq(artStorage.chunkPointer(col, 1, 0).code.length, 24_576);
    }

    function test_curatorRepairsOrDropsAnUnfinalizedPiece() public {
        vm.startPrank(ARTIST);
        house.registerPiece(col, 1, keccak256("typo"), "T", "D");
        house.uploadChunk(col, 1, 0, SVG);
        vm.expectRevert(
            abi.encodeWithSelector(ArtStorage.ContentHashMismatch.selector, keccak256("typo"), keccak256(SVG))
        );
        house.finalizePiece(col, 1);
        // the artist cannot repair; the curator can, without re-uploading
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ARTIST));
        house.redescribePiece(col, 1, keccak256(SVG), "Piece", "fixed");
        vm.stopPrank();
        vm.prank(OWNER);
        house.redescribePiece(col, 1, keccak256(SVG), "Piece", "fixed");
        (bytes32 h, string memory title,,,,) = artStorage.pieceInfo(col, 1);
        assertEq(h, keccak256(SVG));
        assertEq(title, "Piece");
        vm.prank(ARTIST);
        house.finalizePiece(col, 1);
        vm.prank(OWNER);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.redescribePiece(col, 1, keccak256("other"), "x", "y");
        // a junk piece registered after it is dropped, and the slot can be used again
        vm.prank(ARTIST);
        house.registerPiece(col, 2, bytes32(0), "junk", "");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ArtStorage.PieceNotFinalized.selector, 2));
        house.seal(col);
        vm.prank(ARTIST);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ARTIST));
        house.dropLastPiece(col);
        vm.prank(OWNER);
        house.dropLastPiece(col);
        assertEq(artStorage.pieceCount(col), 1);
        vm.expectRevert(ArtStorage.UnknownPiece.selector);
        artStorage.pieceInfo(col, 2);
        vm.prank(OWNER);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.dropLastPiece(col);
        vm.prank(OWNER);
        house.seal(col);
        vm.prank(OWNER);
        vm.expectRevert(ArtStorage.CollectionSealedAlready.selector);
        house.dropLastPiece(col);
        vm.prank(OWNER);
        vm.expectRevert(ArtStorage.CollectionSealedAlready.selector);
        house.redescribePiece(col, 1, keccak256("other"), "x", "y");
        assertEq(token.maxSupply(), 1);
    }

    function test_revokedArtistLosesWriteAccessUntilReapproved() public {
        vm.prank(OWNER);
        house.revokeArtist(ARTIST);
        vm.startPrank(ARTIST);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.registerPiece(col, 1, keccak256(SVG), "t", "d");
        vm.stopPrank();
        vm.prank(OWNER);
        house.registerPiece(col, 1, keccak256(SVG), "t", "d");
        vm.startPrank(ARTIST);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.uploadChunk(col, 1, 0, SVG);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.finalizePiece(col, 1);
        vm.stopPrank();
        vm.prank(BOB);
        vm.expectRevert(ArtHouse.NotCuratorOrArtist.selector);
        house.uploadChunk(col, 1, 0, SVG);
        vm.prank(OWNER);
        house.approveArtist(ARTIST, "Myles", ARTIST_PAYOUT);
        vm.startPrank(ARTIST);
        house.uploadChunk(col, 1, 0, SVG);
        house.finalizePiece(col, 1);
        vm.stopPrank();
    }

    function test_reapprovingAnArtistKeepsItsPayout() public {
        vm.prank(ARTIST);
        house.setPayout(address(0xBEEF));
        vm.prank(OWNER);
        house.approveArtist(ARTIST, "Myles renamed", OWNER);
        assertEq(house.artist(ARTIST).payout, address(0xBEEF));
        assertEq(house.artist(ARTIST).name, "Myles renamed");
        assertEq(house.royaltyReceiver(col), address(0xBEEF));
        // after a revocation the curator sets the payout again
        vm.startPrank(OWNER);
        house.revokeArtist(ARTIST);
        house.approveArtist(ARTIST, "Myles", ARTIST_PAYOUT);
        vm.stopPrank();
        assertEq(house.artist(ARTIST).payout, ARTIST_PAYOUT);
    }

    function test_setSplitOnlyWhileSvgSaleClosed() public {
        _uploadAndSeal(col, 1);
        _openEth(1 ether);
        vm.prank(OWNER);
        vm.expectRevert(ArtHouse.SaleOpen.selector);
        house.setSplit(col, 0, 10_000, 0);
        vm.startPrank(OWNER);
        house.closeSale(col);
        house.setSplit(col, 1000, 2000, 7000);
        vm.stopPrank();
        assertEq(house.collection(col).artistBps, 7000);
    }

    function test_tokenURIEscapesTitleAndDescription() public {
        vm.startPrank(ARTIST);
        house.registerPiece(col, 1, keccak256(SVG), 'A"B', "back\\slash\nline");
        house.uploadChunk(col, 1, 0, SVG);
        house.finalizePiece(col, 1);
        vm.stopPrank();
        vm.prank(OWNER);
        house.seal(col);
        _openEth(1 ether);
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, address(0));
        string memory json = B64.decodeDataURI(token.tokenURI(1), "data:application/json;base64,");
        assertEq(
            json,
            string.concat(
                '{"name":"A\\"B","description":"back\\\\slash\\u000aline","image":"data:image/svg+xml;base64,',
                Base64.encode(SVG),
                '"}'
            )
        );
    }
}
