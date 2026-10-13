// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtStorage} from "../src/ArtStorage.sol";
import {ArtCollection} from "../src/ArtCollection.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {ArtifactsSale} from "../src/ArtifactsSale.sol";
import {ArtifactsAuction} from "../src/ArtifactsAuction.sol";
import {ArtifactsEscrow} from "../src/ArtifactsEscrow.sol";
import {Traits} from "../src/libraries/ArtifactsSeal.sol";
import {JsonEscape} from "../src/libraries/JsonEscape.sol";
import {Rejector} from "./mocks/Mocks.sol";
import {B64} from "./mocks/B64.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

/// @dev Bidder that cannot receive ETH: its own refund is stuck, nobody else's is.
contract RejectingBidder {
    function bid(ArtifactsAuction a) external payable {
        a.bid{value: msg.value}();
    }

    function pull(ArtifactsAuction a) external {
        a.withdrawRefund();
    }
}

/// @dev Re-enters the escrow refund while being paid.
contract EscrowReenterer {
    ArtifactsEscrow internal escrow;
    bool public reentered;

    constructor(ArtifactsEscrow e) {
        escrow = e;
    }

    function buy(uint16 id) external payable {
        escrow.buy{value: msg.value}(id, bytes32(uint256(7)));
    }

    function cancel(uint16 id) external {
        escrow.cancel(id);
    }

    function pull() external {
        escrow.withdrawRefund();
    }

    receive() external payable {
        (bool ok,) = address(escrow).call(abi.encodeWithSelector(ArtifactsEscrow.withdrawRefund.selector));
        reentered = ok;
    }
}

contract HouseFailurePathsTest is Fixture {
    uint256 internal col;
    ArtCollection internal token;
    bytes internal constant SVG = '<svg xmlns="http://www.w3.org/2000/svg"/>';

    function setUp() public override {
        super.setUp();
        vm.startPrank(OWNER);
        address tk;
        (col, tk) = house.createCollection(ARTIST, "Later", "LATER");
        token = ArtCollection(tk);
        vm.stopPrank();
    }

    function _sealOne() internal {
        vm.startPrank(ARTIST);
        house.registerPiece(col, 1, keccak256(SVG), "P", "D");
        house.uploadChunk(col, 1, 0, SVG);
        house.finalizePiece(col, 1);
        vm.stopPrank();
        vm.prank(OWNER);
        house.seal(col);
    }

    function test_mintFailsWhileClosedUnpricedOrWrongValue() public {
        _sealOne();
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.SaleNotOpen.selector);
        house.mint{value: 1 ether}(col, 1, address(0));

        vm.startPrank(OWNER);
        house.setPrices(col, 0, 100 ether); // IMD only
        house.openSale(col);
        vm.expectRevert(ArtHouse.SaleOpen.selector);
        house.setPrices(col, 1 ether, 100 ether);
        vm.stopPrank();

        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NoPrice.selector);
        house.mint{value: 0}(col, 1, address(0));

        vm.startPrank(OWNER);
        house.closeSale(col);
        house.setPrices(col, 1 ether, 0);
        house.openSale(col);
        vm.stopPrank();

        vm.startPrank(ALICE);
        vm.expectRevert(ArtHouse.NoPrice.selector);
        house.mintWithIMD(col, 1, address(0), 0);
        vm.expectRevert(ArtHouse.WrongPayment.selector);
        house.mint{value: 1 ether - 1}(col, 1, address(0));
        vm.expectRevert(ArtHouse.WrongPayment.selector);
        house.mint{value: 1 ether + 1}(col, 1, address(0));
        vm.expectRevert(ArtStorage.UnknownPiece.selector);
        house.mint{value: 1 ether}(col, 2, address(0));
        vm.expectRevert(ArtStorage.UnknownPiece.selector);
        house.mint{value: 1 ether}(col, 0, address(0));
        house.mint{value: 1 ether}(col, 1, address(0));
        vm.stopPrank();

        // the same piece can never be bought twice
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        house.mint{value: 1 ether}(col, 1, address(0));
        assertEq(address(house).balance, 1 ether);
    }

    function test_mintWithIMDWrongPriceOrNoAllowancePullsNothing() public {
        _sealOne();
        vm.startPrank(OWNER);
        house.setPrices(col, 0, 100 ether);
        house.openSale(col);
        vm.stopPrank();
        imd.mint(ALICE, 200 ether);
        vm.startPrank(ALICE);
        imd.approve(address(house), 200 ether);
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mintWithIMD(col, 1, address(0), 99 ether);
        vm.expectRevert(ArtHouse.WrongPrice.selector);
        house.mintWithIMD(col, 1, address(0), 101 ether);
        imd.approve(address(house), 50 ether);
        vm.expectRevert();
        house.mintWithIMD(col, 1, address(0), 100 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(ALICE), 200 ether);
        assertEq(house.balances(address(house), address(imd)), 0);
        vm.expectRevert();
        token.ownerOf(1);
    }

    function test_unfinalizedPieceCannotBeSoldAndModuleCollectionHasNoSvgSale() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArtHouse.NotSvgCollection.selector);
        house.setPrices(artifactsCollection, 1, 1);
        vm.expectRevert(ArtHouse.NotSvgCollection.selector);
        house.openSale(artifactsCollection);
        vm.expectRevert(ArtHouse.NotSvgCollection.selector);
        house.registerPiece(artifactsCollection, 1, bytes32(0), "a", "b");
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.setPrices(99, 1, 1);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.approveModule(address(0xBEEF), 99);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.approveModule(address(0xBEEF), 0);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NotSvgCollection.selector);
        house.mint{value: 1}(artifactsCollection, 1, address(0));
    }

    function test_strangersCannotUploadAndArtistCannotClear() public {
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NotCuratorOrArtist.selector);
        house.registerPiece(col, 1, keccak256(SVG), "P", "D");
        vm.prank(ARTIST);
        house.registerPiece(col, 1, keccak256(SVG), "P", "D");
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NotCuratorOrArtist.selector);
        house.uploadChunk(col, 1, 0, SVG);
        vm.prank(ARTIST);
        house.uploadChunk(col, 1, 0, SVG);
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NotCuratorOrArtist.selector);
        house.finalizePiece(col, 1);
        vm.prank(ARTIST);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ARTIST));
        house.clearPiece(col, 1);
        vm.prank(ARTIST);
        vm.expectRevert(ArtStorage.EmptyChunk.selector);
        house.uploadChunk(col, 1, 1, "");
        vm.prank(ARTIST);
        house.finalizePiece(col, 1);
        vm.startPrank(OWNER);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.clearPiece(col, 1);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.uploadChunk(col, 1, 1, SVG);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.finalizePiece(col, 1);
        house.seal(col);
        vm.expectRevert(ArtStorage.CollectionSealedAlready.selector);
        house.seal(col);
        vm.expectRevert(ArtStorage.CollectionSealedAlready.selector);
        house.registerPiece(col, 2, keccak256(SVG), "P", "D");
        vm.stopPrank();
    }

    function test_emptyPieceCannotBeFinalizedAndEmptyCollectionCannotBeSealed() public {
        vm.prank(OWNER);
        vm.expectRevert(ArtStorage.NoPieces.selector);
        house.seal(col);
        vm.prank(ARTIST);
        house.registerPiece(col, 1, keccak256(""), "P", "D");
        vm.prank(ARTIST);
        vm.expectRevert(ArtStorage.EmptyPiece.selector);
        house.finalizePiece(col, 1);
    }

    function test_createCollectionNeedsApprovedArtistAndNames() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.createCollection(ALICE, "N", "S");
        vm.expectRevert(ArtHouse.EmptyName.selector);
        house.createCollection(ARTIST, "", "S");
        vm.expectRevert(ArtHouse.EmptyName.selector);
        house.createCollection(ARTIST, "N", "");
        house.revokeArtist(ARTIST);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.createModuleCollection(ARTIST);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        house.createCollection(ARTIST, "N", "S");
    }

    function test_splitMustSumToFullBps() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArtHouse.BadSplit.selector);
        house.setSplit(col, 1500, 1500, 6999);
        vm.expectRevert(ArtHouse.BadSplit.selector);
        house.setSplit(col, 1500, 1500, 7001);
        vm.expectRevert(ArtHouse.BadSplit.selector);
        house.setSplit(col, type(uint16).max, type(uint16).max, 2);
        house.setSplit(col, 0, 10_000, 0);
        vm.stopPrank();
        ArtHouse.Collection memory c = house.collection(col);
        assertEq(c.houseBps, 10_000);
    }

    function test_revokedModuleCannotRecordAndResaleRejectsZero() public {
        vm.deal(address(sale), 1 ether);
        vm.prank(address(sale));
        vm.expectRevert(ArtHouse.WrongPayment.selector);
        house.recordSale{value: 0}(ALICE, address(0));
        vm.prank(address(sale));
        vm.expectRevert(ArtHouse.WrongPayment.selector);
        house.recordResale{value: 1}(address(0));
        vm.prank(address(sale));
        vm.expectRevert(ArtHouse.WrongPayment.selector);
        house.recordResale{value: 0}(ALICE);
        vm.prank(OWNER);
        house.revokeModule(address(sale));
        vm.prank(address(sale));
        vm.expectRevert(ArtHouse.NotModule.selector);
        house.recordSale{value: 1}(ALICE, address(0));
        vm.prank(address(sale));
        vm.expectRevert(ArtHouse.NotModule.selector);
        house.recordResale{value: 1}(ALICE);
        // a revoked module keeps its collection on record so royalties still resolve; a stranger never had one
        assertEq(house.moduleRoyaltyReceiver(address(sale)), ARTIST_PAYOUT);
        assertEq(house.moduleCollection(address(sale)), artifactsCollection);
        assertFalse(house.isModule(address(sale)));
        vm.expectRevert(ArtHouse.NotModule.selector);
        house.moduleRoyaltyReceiver(ALICE);
        // revoking a stranger is harmless and does not make it a module
        vm.prank(OWNER);
        house.revokeModule(ALICE);
        assertFalse(house.isModule(ALICE));
        vm.deal(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(ArtHouse.NotModule.selector);
        house.recordSale{value: 1}(BOB, address(0));
        // re-approval restores recording with the same collection
        vm.prank(OWNER);
        house.approveModule(address(sale), artifactsCollection);
        vm.prank(address(sale));
        house.recordSale{value: 1 ether}(ALICE, address(0));
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 0.7 ether);
    }

    function test_splitOfOpenSvgSaleIsFrozenButModuleCollectionIsNot() public {
        _sealOne();
        vm.startPrank(OWNER);
        house.setPrices(col, 1 ether, 0);
        house.openSale(col);
        vm.expectRevert(ArtHouse.SaleOpen.selector);
        house.setSplit(col, 0, 10_000, 0);
        // the ARTIFACTS ledger collection has no sale state here, so its split can change at any time
        house.setSplit(artifactsCollection, 0, 10_000, 0);
        house.closeSale(col);
        house.setSplit(col, 0, 10_000, 0);
        house.openSale(col);
        vm.stopPrank();
        ArtHouse.Collection memory c = house.collection(col);
        assertEq(c.houseBps, 10_000);
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, BROKER);
        assertEq(house.balances(address(house), ETH), 1 ether);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 0);
        assertEq(house.balances(BROKER, ETH), 0);
    }

    function test_reapprovingAnArtistKeepsItsPayoutAndRevocationRemovesWriteAccess() public {
        vm.prank(ARTIST);
        house.setPayout(address(0x5EED));
        vm.prank(OWNER);
        house.approveArtist(ARTIST, "Renamed", address(0xBAD));
        ArtHouse.Artist memory a = house.artist(ARTIST);
        assertEq(a.name, "Renamed");
        assertEq(a.payout, address(0x5EED));
        assertTrue(a.approved);
        vm.prank(OWNER);
        vm.expectRevert(ArtHouse.ZeroAddress.selector);
        house.approveArtist(ARTIST, "Renamed", address(0));

        vm.prank(ARTIST);
        house.registerPiece(col, 1, keccak256(SVG), "P", "D");
        vm.prank(OWNER);
        house.revokeArtist(ARTIST);
        vm.startPrank(ARTIST);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.uploadChunk(col, 1, 0, SVG);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.registerPiece(col, 2, keccak256(SVG), "P", "D");
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.finalizePiece(col, 1);
        vm.expectRevert(ArtHouse.NotApprovedArtist.selector);
        house.setPayout(ALICE);
        vm.stopPrank();
        // the curator keeps access; the artist's payout survives the revocation for royalties already owed
        vm.prank(OWNER);
        house.uploadChunk(col, 1, 0, SVG);
        assertEq(house.royaltyReceiver(col), address(0x5EED));
        vm.prank(OWNER);
        house.approveArtist(ARTIST, "Back", address(0xBAD));
        vm.prank(ARTIST);
        house.finalizePiece(col, 1);
    }

    function test_repairFunctionsAreCuratorOnlyAndRespectFinalizeAndSeal() public {
        vm.prank(ARTIST);
        house.registerPiece(col, 1, keccak256("wrong"), "P", "D");
        vm.startPrank(ARTIST);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ARTIST));
        house.redescribePiece(col, 1, keccak256(SVG), "P", "D");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ARTIST));
        house.dropLastPiece(col);
        vm.stopPrank();
        vm.startPrank(OWNER);
        vm.expectRevert(ArtHouse.NotSvgCollection.selector);
        house.redescribePiece(artifactsCollection, 1, keccak256(SVG), "P", "D");
        vm.expectRevert(ArtHouse.NotSvgCollection.selector);
        house.dropLastPiece(artifactsCollection);
        vm.expectRevert(ArtHouse.UnknownCollection.selector);
        house.dropLastPiece(99);
        vm.expectRevert(ArtStorage.UnknownPiece.selector);
        house.redescribePiece(col, 2, keccak256(SVG), "P", "D");
        vm.expectRevert(ArtStorage.UnknownPiece.selector);
        house.redescribePiece(col, 0, keccak256(SVG), "P", "D");
        // the wrong hash blocks finalize until it is repaired; uploaded bytes survive the repair
        house.uploadChunk(col, 1, 0, SVG);
        vm.expectRevert(
            abi.encodeWithSelector(ArtStorage.ContentHashMismatch.selector, keccak256("wrong"), keccak256(SVG))
        );
        house.finalizePiece(col, 1);
        house.redescribePiece(col, 1, keccak256(SVG), "Fixed", "D2");
        (,,,, uint256 chunks,) = artStorage.pieceInfo(col, 1);
        assertEq(chunks, 1);
        // a mistaken second registration is dropped, the first is finalized, the same id can be reused and sealed
        house.registerPiece(col, 2, keccak256("oops"), "X", "Y");
        house.registerPiece(col, 3, keccak256("oops"), "X", "Y");
        house.uploadChunk(col, 3, 0, SVG);
        house.dropLastPiece(col);
        assertEq(artStorage.pieceCount(col), 2);
        vm.expectRevert(ArtStorage.UnknownPiece.selector);
        artStorage.pieceInfo(col, 3);
        house.finalizePiece(col, 1);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.redescribePiece(col, 1, keccak256("other"), "P", "D");
        vm.expectRevert(abi.encodeWithSelector(ArtStorage.PieceNotFinalized.selector, 2));
        house.seal(col);
        house.dropLastPiece(col);
        vm.expectRevert(ArtStorage.PieceFinalizedAlready.selector);
        house.dropLastPiece(col);
        house.registerPiece(col, 2, keccak256(SVG), "P2", "D");
        house.uploadChunk(col, 2, 0, SVG);
        (,,,, chunks,) = artStorage.pieceInfo(col, 2);
        assertEq(chunks, 1, "a re-registered id starts empty");
        house.finalizePiece(col, 2);
        house.seal(col);
        vm.expectRevert(ArtStorage.CollectionSealedAlready.selector);
        house.dropLastPiece(col);
        vm.expectRevert(ArtStorage.CollectionSealedAlready.selector);
        house.redescribePiece(col, 2, keccak256(SVG), "P", "D");
        vm.stopPrank();
        assertEq(token.maxSupply(), 2);
    }

    function _filled(uint256 n, bytes1 c) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = c;
        }
    }

    function _slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = b[start + i];
        }
    }

    function test_chunkAndPieceLimitsAtTheExactBoundary() public {
        uint256 maxChunk = artStorage.MAX_CHUNK_BYTES();
        uint256 maxPiece = artStorage.MAX_PIECE_BYTES();
        assertEq(maxChunk, 24_575);
        assertEq(maxPiece, 102_400);
        bytes memory full = _filled(maxPiece, "a");
        vm.startPrank(OWNER);
        house.registerPiece(col, 1, keccak256(full), "Big", "D");
        vm.expectRevert(ArtStorage.ChunkTooLarge.selector);
        house.uploadChunk(col, 1, 0, _filled(maxChunk + 1, "a"));
        // exactly the chunk limit is accepted and read back intact
        house.uploadChunk(col, 1, 0, _slice(full, 0, maxChunk));
        assertEq(artStorage.pieceBytes(col, 1).length, maxChunk);
        uint256 off = maxChunk;
        uint256 idx = 1;
        while (off < maxPiece) {
            uint256 len = maxPiece - off < maxChunk ? maxPiece - off : maxChunk;
            house.uploadChunk(col, 1, idx++, _slice(full, off, len));
            off += len;
        }
        // one byte over the piece limit is refused even though the chunk itself is tiny
        vm.expectRevert(ArtStorage.PieceTooLarge.selector);
        house.uploadChunk(col, 1, idx, "b");
        (,,, uint256 size, uint256 chunks,) = artStorage.pieceInfo(col, 1);
        assertEq(size, maxPiece);
        assertEq(chunks, 5);
        assertEq(keccak256(artStorage.pieceBytes(col, 1)), keccak256(full));
        house.finalizePiece(col, 1);
        vm.stopPrank();
    }

    /// @dev The README claims a 100 KB piece in 100 chunks finalizes well under the block gas limit.
    function test_hundredChunkPieceFinalizesUnderBlockGas() public {
        uint256 n = 100;
        uint256 chunk = 1024;
        bytes memory full = _filled(n * chunk, "z");
        vm.startPrank(OWNER);
        house.registerPiece(col, 1, keccak256(full), "Many", "D");
        for (uint256 i; i < n; ++i) {
            house.uploadChunk(col, 1, i, _slice(full, i * chunk, chunk));
        }
        uint256 g = gasleft();
        house.finalizePiece(col, 1);
        g -= gasleft();
        vm.stopPrank();
        assertLt(g, 30_000_000);
        (,,,,, bool fin) = artStorage.pieceInfo(col, 1);
        assertTrue(fin);
        assertEq(artStorage.chunkPointer(col, 1, 99).code.length, chunk + 1);
        vm.expectRevert();
        artStorage.chunkPointer(col, 1, 100);
    }

    function test_tokenURIEscapesArtistText() public {
        string memory title = 'He said "hi" \\ now';
        string memory desc = "line1\nline2\ttab\x01";
        vm.startPrank(OWNER);
        house.registerPiece(col, 1, keccak256(SVG), title, desc);
        house.uploadChunk(col, 1, 0, SVG);
        house.finalizePiece(col, 1);
        house.seal(col);
        house.setPrices(col, 1 ether, 0);
        house.openSale(col);
        vm.stopPrank();
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, address(0));
        string memory json = B64.decodeDataURI(token.tokenURI(1), "data:application/json;base64,");
        assertEq(
            json,
            string.concat(
                '{"name":"He said \\"hi\\" \\\\ now","description":"line1\\u000aline2\\u0009tab\\u0001",',
                '"image":"data:image/svg+xml;base64,',
                Base64.encode(SVG),
                '"}'
            )
        );
    }

    /// @dev Unescapes a JSON string body produced by JsonEscape; reverts on anything the escaper must never emit.
    function _unescape(bytes memory o) internal pure returns (bytes memory out) {
        out = new bytes(o.length);
        uint256 n;
        for (uint256 i; i < o.length; ++i) {
            bytes1 c = o[i];
            if (c == "\\") {
                bytes1 d = o[++i];
                if (d == "\\" || d == '"') {
                    out[n++] = d;
                } else if (d == "u") {
                    require(o[i + 1] == "0" && o[i + 2] == "0", "not \\u00xx");
                    out[n++] = bytes1(uint8(_hex(o[i + 3]) * 16 + _hex(o[i + 4])));
                    i += 4;
                } else {
                    revert("bad escape");
                }
            } else {
                require(c != '"' && uint8(c) >= 0x20, "raw control or quote");
                out[n++] = c;
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _hex(bytes1 c) internal pure returns (uint8) {
        uint8 x = uint8(c);
        if (x >= 48 && x <= 57) return x - 48;
        require(x >= 97 && x <= 102, "not hex");
        return x - 87;
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_jsonEscapeRoundTripsAndEmitsNoRawQuotesOrControls(bytes memory raw) public pure {
        string memory escaped = JsonEscape.escape(string(raw));
        assertEq(_unescape(bytes(escaped)), raw);
        assertGe(bytes(escaped).length, raw.length);
    }

    function test_jsonEscapePinnedEdges() public pure {
        assertEq(JsonEscape.escape(""), "");
        assertEq(JsonEscape.escape("plain"), "plain");
        assertEq(JsonEscape.escape('"'), '\\"');
        assertEq(JsonEscape.escape("\\"), "\\\\");
        assertEq(JsonEscape.escape("\x00"), "\\u0000");
        assertEq(JsonEscape.escape("\x1f"), "\\u001f");
        assertEq(JsonEscape.escape("\x7f"), "\x7f");
        assertEq(JsonEscape.escape(unicode"é"), unicode"é");
    }

    function test_houseBalanceFollowsOwnershipAndNotOldOwner() public {
        vm.deal(address(sale), 1 ether);
        vm.prank(address(sale));
        house.recordSale{value: 1 ether}(ALICE, address(0));
        assertEq(house.balances(address(house), ETH), 0.3 ether);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        house.withdrawHouse(ETH);

        address next = address(0x0E0E);
        vm.prank(OWNER);
        house.transferOwnership(next);
        vm.prank(next);
        house.acceptOwnership();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        house.withdrawHouse(ETH);
        vm.prank(next);
        house.withdrawHouse(ETH);
        assertEq(next.balance, 0.3 ether);
        vm.prank(next);
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.withdrawHouse(ETH);
        // nobody can pull the house's balance through withdraw()
        vm.prank(address(house));
        vm.expectRevert(ArtHouse.NothingToWithdraw.selector);
        house.withdraw(ETH);
    }

    function test_royaltyFollowsCurrentPayoutAndIs750Bps() public {
        _sealOne();
        vm.startPrank(OWNER);
        house.setPrices(col, 1 ether, 0);
        house.openSale(col);
        vm.stopPrank();
        vm.prank(ALICE);
        house.mint{value: 1 ether}(col, 1, address(0));
        (address r, uint256 amt) = token.royaltyInfo(1, 10_000);
        assertEq(r, ARTIST_PAYOUT);
        assertEq(amt, 750);
        vm.prank(ARTIST);
        house.setPayout(address(0x5EED));
        (r, amt) = token.royaltyInfo(1, 1 ether);
        assertEq(r, address(0x5EED));
        assertEq(amt, 0.075 ether);
        assertTrue(token.supportsInterface(type(IERC2981).interfaceId));
        // already credited sale proceeds stay with the old payout address
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 0.7 ether);
    }

    function test_submissionUnknownIdsRevert() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArtHouse.UnknownSubmission.selector);
        house.acceptSubmission(0);
        vm.expectRevert(ArtHouse.UnknownSubmission.selector);
        house.rejectSubmission(1);
        vm.stopPrank();
        vm.prank(ALICE);
        uint256 id = house.submit(keccak256("x"), "ipfs://x");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        house.acceptSubmission(id);
        vm.prank(OWNER);
        house.rejectSubmission(id);
        vm.prank(OWNER);
        vm.expectRevert(ArtHouse.SubmissionDecidedAlready.selector);
        house.acceptSubmission(id);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_withdrawPaysOnlyOwnBalance(uint96 a, uint96 b) public {
        uint256 x = bound(a, 1, 100 ether);
        uint256 y = bound(b, 1, 100 ether);
        vm.deal(address(sale), x + y);
        vm.startPrank(address(sale));
        house.recordResale{value: x}(ALICE);
        house.recordResale{value: y}(BOB);
        vm.stopPrank();
        uint256 aliceOwed = house.balances(ALICE, ETH);
        assertEq(aliceOwed, x - x * 750 / 10_000);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        house.withdraw(ETH);
        assertEq(ALICE.balance - before, aliceOwed);
        assertEq(house.balances(BOB, ETH), y - y * 750 / 10_000);
        assertEq(address(house).balance, house.balances(BOB, ETH) + house.balances(ARTIST_PAYOUT, ETH));
    }
}

contract ArtifactsFailurePathsTest is Fixture {
    function setUp() public override {
        super.setUp();
        uploadAllPieces();
    }

    // ---------------------------------------------------------------- sale

    function test_saleAdminFailures() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsSale.NoPrice.selector);
        sale.openSale();
        vm.expectRevert(ArtifactsSale.NoPrice.selector);
        sale.setPrice(0);
        vm.expectRevert(ArtifactsSale.ZeroAddress.selector);
        sale.configureVRF(address(0), bytes32(uint256(1)), 1, false);
        vm.expectRevert(ArtifactsSale.ZeroAddress.selector);
        sale.configureVRF(address(vrf), bytes32(0), 1, false);
        vm.expectRevert(ArtifactsSale.ZeroAddress.selector);
        sale.configureVRF(address(vrf), bytes32(uint256(1)), 0, false);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        sale.configureVRF(address(vrf), bytes32(uint256(1)), 1, false);

        configureAndOpenSale(1 ether);
        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsSale.VRFAlreadyConfigured.selector);
        sale.configureVRF(address(0xBEEF), bytes32(uint256(2)), 2, true);
        vm.expectRevert(ArtifactsSale.SaleIsOpen.selector);
        sale.setPrice(2 ether);
        vm.stopPrank();
        assertEq(sale.vrfCoordinator(), address(vrf));
        assertEq(sale.price(), 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        sale.closeSale();
    }

    function test_buyFailures() public {
        configureAndOpenSale(1 ether);
        vm.startPrank(ALICE);
        vm.expectRevert(ArtifactsSale.WrongPayment.selector);
        sale.buy{value: 1 ether - 1}(BROKER);
        vm.expectRevert(ArtifactsSale.WrongPayment.selector);
        sale.buy{value: 1 ether + 1}(BROKER);
        vm.expectRevert(ArtifactsSale.WrongPayment.selector);
        sale.buy{value: 0}(BROKER);
        vm.stopPrank();
        vm.prank(OWNER);
        sale.closeSale();
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsSale.SaleNotOpen.selector);
        sale.buy{value: 1 ether}(BROKER);
        assertEq(sale.purchaseCount(), 0);
        assertEq(address(house).balance, 0);
    }

    function test_256thPurchaseIsSoldOut() public {
        configureAndOpenSale(1 wei);
        for (uint256 i; i < 255; ++i) {
            vm.prank(ALICE);
            sale.buy{value: 1}(address(0));
        }
        vm.prank(BOB);
        vm.expectRevert(ArtifactsSale.SoldOut.selector);
        sale.buy{value: 1}(address(0));
        assertEq(sale.purchaseCount(), 255);
    }

    function test_onlyCoordinatorFulfilsAndRetryRules() public {
        configureAndOpenSale(1 ether);
        vm.prank(ALICE);
        uint256 pid = sale.buy{value: 1 ether}(address(0));
        uint256[] memory words = new uint256[](1);
        uint256 reqId = sale.purchase(pid).requestId;
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsSale.NotCoordinator.selector);
        sale.rawFulfillRandomWords(reqId, words);
        // empty words are ignored rather than reverting
        vm.prank(address(vrf));
        sale.rawFulfillRandomWords(reqId, new uint256[](0));
        assertEq(sale.purchase(pid).edition, 0);

        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsSale.UnknownPurchase.selector);
        sale.retryRequest(pid + 1);
        vm.expectRevert(ArtifactsSale.TooEarly.selector);
        sale.retryRequest(pid);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        sale.retryRequest(pid);
        vm.prank(OWNER);
        sale.retryRequest(pid);
        vrf.fulfill(sale.purchase(pid).requestId, 5);
        assertTrue(sale.purchase(pid).edition != 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsSale.AlreadyAssigned.selector);
        sale.retryRequest(pid);
    }

    /// @dev Chainlink calls back with exactly callbackGasLimit; the assignment must fit inside it.
    function test_fulfilmentFitsCallbackGasLimit() public {
        configureAndOpenSale(1 ether);
        vm.prank(ALICE);
        uint256 pid = sale.buy{value: 1 ether}(address(0));
        uint256[] memory words = new uint256[](1);
        words[0] = 200; // touches a far slot and the last slot, both cold
        uint256 reqId = sale.purchase(pid).requestId;
        uint256 limit = sale.CALLBACK_GAS_LIMIT();
        vm.prank(address(vrf));
        (bool ok,) = address(sale).call{gas: limit}(
            abi.encodeWithSelector(ArtifactsSale.rawFulfillRandomWords.selector, reqId, words)
        );
        assertTrue(ok);
        assertEq(sale.purchase(pid).edition, 201);
        assertEq(factory.assignedTo(201), ALICE);
    }

    function test_vrfRequestCarriesConfiguredParameters() public {
        configureAndOpenSale(1 ether);
        vm.prank(ALICE);
        sale.buy{value: 1 ether}(address(0));
        (bytes32 kh, uint256 sub, uint16 conf, uint32 gasLimit, uint32 n, bytes memory extra) = vrf.lastRequest();
        assertEq(kh, bytes32(uint256(1)));
        assertEq(sub, 7);
        assertEq(conf, 3);
        assertEq(gasLimit, 250_000);
        assertEq(n, 1);
        assertEq(extra, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), false));
    }

    // ---------------------------------------------------------------- factory and claim

    function test_factoryLockedAndClaimFailures() public {
        vm.startPrank(OWNER);
        vm.expectRevert(ArtifactsFactory.AlreadyLocked.selector);
        factory.setPiece(1, traitsFor(1), "x", bytes32(0));
        vm.expectRevert(ArtifactsFactory.AlreadyLocked.selector);
        factory.lock();
        vm.expectRevert(ArtifactsFactory.ModulesAlreadySet.selector);
        factory.setModules(address(1), address(2), address(3));
        vm.expectRevert(ArtifactsFactory.NotAssignedBuyer.selector);
        factory.postContentKey(1, "k");
        vm.stopPrank();

        configureAndOpenSale(1 ether);
        uint16 e = buyAndAssign(ALICE, address(0), 3);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsFactory.NotAssignedBuyer.selector);
        factory.claim(e);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.NoWrappedKey.selector);
        factory.claim(e);
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsFactory.NoViewingKey.selector);
        factory.postContentKey(e, "k");
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.EmptyKey.selector);
        factory.registerViewingKey(bytes32(0));
        vm.prank(ALICE);
        factory.registerViewingKey(bytes32(uint256(9)));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        factory.postContentKey(e, "k");
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsFactory.EmptyKey.selector);
        factory.postContentKey(e, "");
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.NotEscrow.selector);
        factory.registerViewingKeyFor(BOB, bytes32(uint256(1)));

        ArtifactsPiece p = claimPiece(e, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsFactory.AlreadyClaimed.selector);
        factory.claim(e);
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsFactory.AlreadyClaimed.selector);
        factory.postContentKey(e, "k2");

        // the clone cannot be re-initialised; neither can the implementation
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        p.initialize(e, BOB, "x");
        vm.expectRevert(ArtifactsPiece.AlreadyInitialized.selector);
        pieceImpl.initialize(e, BOB, "x");
        // the piece serves exactly the ciphertext uploaded before the lock
        assertEq(p.ciphertextBytes(), abi.encodePacked("ciphertext-", e));
        assertEq(p.commitment(), keccak256(abi.encodePacked("K", e)));
        assertEq(p.symbol(), "ARTIFACTS");
        assertEq(p.balanceOf(ALICE), 1);
        vm.expectRevert();
        p.tokenURI(e == 1 ? 2 : 1);
    }

    function test_pieceKeyPostingIsRestricted() public {
        configureAndOpenSale(1 ether);
        uint16 e = buyAndAssign(ALICE, address(0), 3);
        ArtifactsPiece p = claimPiece(e, ALICE);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsPiece.NotKeyPoster.selector);
        p.setWrappedKey("evil");
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsPiece.EmptyKey.selector);
        p.setWrappedKey("");
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsPiece.NotKeyPoster.selector);
        p.setWrappedKey("curator");
        (address r, uint256 amt) = p.royaltyInfo(e, 2 ether);
        assertEq(r, ARTIST_PAYOUT);
        assertEq(amt, 0.15 ether);
    }

    // ---------------------------------------------------------------- auction

    function test_auctionRefundOfRejectingBidderBlocksOnlyItself() public {
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 days));
        RejectingBidder rb = new RejectingBidder();
        vm.deal(address(rb), 0);
        rb.bid{value: 1 ether}(auction);
        vm.prank(ALICE);
        auction.bid{value: 2 ether}();
        vm.expectRevert(ArtifactsAuction.EthTransferFailed.selector);
        rb.pull(auction);
        assertEq(auction.refunds(address(rb)), 1 ether);
        vm.prank(BOB);
        auction.bid{value: 3 ether}();
        vm.prank(ALICE);
        auction.withdrawRefund();
        vm.warp(auction.endTime());
        auction.settle();
        assertEq(factory.assignedTo(256), BOB);
        assertEq(address(auction).balance, 1 ether);
    }

    function test_auctionBidAtExactEndRevertsAndEarlySettleFails() public {
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 hours));
        vm.prank(ALICE);
        auction.bid{value: 1 ether}();
        // self-outbid is allowed but the earlier bid becomes a pull refund
        vm.prank(ALICE);
        auction.bid{value: 1.05 ether}();
        assertEq(auction.refunds(ALICE), 1 ether);
        vm.warp(auction.endTime() - 1);
        vm.expectRevert(ArtifactsAuction.NotEnded.selector);
        auction.settle();
        // a bid one second before the end extends to ten minutes after it
        vm.prank(BOB);
        auction.bid{value: 2 ether}();
        assertEq(auction.endTime(), block.timestamp + 10 minutes);
        vm.warp(auction.endTime());
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsAuction.Ended.selector);
        auction.bid{value: 5 ether}();
        vm.prank(OWNER);
        vm.expectRevert(ArtifactsAuction.AuctionStarted.selector);
        auction.configure(1 ether, uint64(block.timestamp + 1 days));
    }

    function test_auctionSettleWhileRevokedHoldsProceedsAndNeverStrandsTheWinner() public {
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 hours));
        vm.prank(BOB);
        auction.bid{value: 1 ether}();
        vm.prank(ALICE);
        auction.bid{value: 2 ether}();
        vm.warp(auction.endTime());
        vm.prank(OWNER);
        house.revokeModule(address(auction));
        auction.settle();
        assertTrue(auction.settled());
        assertEq(auction.heldProceeds(), 2 ether);
        assertEq(address(auction).balance, 3 ether, "held bid plus BOB's refund");
        assertEq(address(house).balance, 0);
        // the winner is assigned and can claim THE SOURCE before the proceeds ever reach the ledger
        assertEq(factory.assignedTo(256), ALICE);
        ArtifactsPiece src = claimPiece(256, ALICE);
        assertEq(src.ownerOf(256), ALICE);
        assertEq(src.name(), unicode"ARTIFACTS · THE SOURCE");
        // the outbid refund is unaffected by the hold
        vm.prank(BOB);
        auction.withdrawRefund();
        assertEq(address(auction).balance, 2 ether);
        vm.expectRevert(ArtifactsAuction.AlreadySettled.selector);
        auction.settle();
        vm.prank(BOB);
        vm.expectRevert(ArtHouse.NotModule.selector);
        auction.forwardProceeds();
        assertEq(auction.heldProceeds(), 2 ether, "a failed forward keeps the hold");
        vm.prank(OWNER);
        house.approveModule(address(auction), artifactsCollection);
        // anyone may forward; the winner is credited as buyer with no broker, so the broker share goes to the house
        vm.prank(BOB);
        auction.forwardProceeds();
        assertEq(address(auction).balance, 0);
        assertEq(address(house).balance, 2 ether);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), 1.4 ether);
        assertEq(house.balances(address(house), ETH), 0.6 ether);
        vm.expectRevert(ArtifactsAuction.NothingHeld.selector);
        auction.forwardProceeds();
        // forwarding is a one-off: a second revocation cannot recreate a hold
        vm.prank(OWNER);
        house.revokeModule(address(auction));
        vm.expectRevert(ArtifactsAuction.NothingHeld.selector);
        auction.forwardProceeds();
    }

    function test_auctionWithApprovedModuleHoldsNothing() public {
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 hours));
        vm.prank(ALICE);
        auction.bid{value: 1 ether}();
        vm.warp(auction.endTime());
        auction.settle();
        assertEq(auction.heldProceeds(), 0);
        assertEq(address(auction).balance, 0);
        vm.expectRevert(ArtifactsAuction.NothingHeld.selector);
        auction.forwardProceeds();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_minimumBidIsStrictlyAboveAndAtLeastFivePercentOver(uint256 first) public {
        vm.prank(OWNER);
        auction.configure(1, uint64(block.timestamp + 1 days));
        first = bound(first, 1, 1e30);
        vm.deal(ALICE, first);
        vm.prank(ALICE);
        auction.bid{value: first}();
        uint256 min = auction.minimumBid();
        assertGt(min, first, "never equal to the high bid");
        assertGe((min - first) * 10_000, first * 500, "at least five percent");
        assertLt((min - first) * 10_000, first * 500 + 10_000, "rounded up by less than one wei of bps");
        vm.deal(BOB, min);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ArtifactsAuction.BelowIncrement.selector, min));
        auction.bid{value: min - 1}();
        vm.prank(BOB);
        auction.bid{value: min}();
        assertEq(auction.highBidder(), BOB);
        assertEq(auction.refunds(ALICE), first);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_bidBelowFivePercentStepReverts(uint256 first, uint256 shortBy) public {
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 days));
        first = bound(first, 1 ether, 500 ether);
        vm.prank(ALICE);
        auction.bid{value: first}();
        uint256 min = auction.minimumBid();
        assertGe(min * 10_000 + 10_000, first * 10_500);
        shortBy = bound(shortBy, 1, min - first);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ArtifactsAuction.BelowIncrement.selector, min));
        auction.bid{value: min - shortBy}();
        assertEq(auction.highBidder(), ALICE);
    }

    // ---------------------------------------------------------------- escrow

    function test_escrowStateMachineFailures() public {
        configureAndOpenSale(1 ether);
        uint16 e = buyAndAssign(ALICE, address(0), 3);
        ArtifactsPiece p = claimPiece(e, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.postKey(e, "k");
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.cancel(e);
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.release(e);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.cancelListing(e);

        vm.prank(ALICE);
        escrow.list(e, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsFactory.EmptyKey.selector);
        escrow.buy{value: 1 ether}(e, bytes32(0));
        vm.prank(BOB);
        escrow.buy{value: 1 ether}(e, bytes32(uint256(1)));
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.ListingFunded.selector);
        escrow.cancelListing(e);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NotPieceOwner.selector); // the escrow holds it
        escrow.list(e, 9 ether);
        // the seller cannot pull the piece back out of escrow
        vm.prank(ALICE);
        vm.expectRevert();
        p.transferFrom(address(escrow), ALICE, e);
        vm.prank(ALICE);
        escrow.postKey(e, "k");
        vm.warp(block.timestamp + 72 hours);
        escrow.release(e);
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.release(e);
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.confirm(e);
        assertEq(address(escrow).balance, 0);
        assertEq(p.ownerOf(e), BOB);
    }

    function test_escrowReleaseWhileRevokedHoldsThePriceForTheSellerWithoutRoyalty() public {
        configureAndOpenSale(1 ether);
        uint16 e = buyAndAssign(ALICE, address(0), 3);
        ArtifactsPiece p = claimPiece(e, ALICE);
        uint256 artistBefore = house.balances(ARTIST_PAYOUT, ETH);
        vm.prank(ALICE);
        escrow.list(e, 2 ether);
        vm.prank(BOB);
        escrow.buy{value: 2 ether}(e, bytes32(uint256(1)));
        vm.prank(ALICE);
        escrow.postKey(e, "rewrapped");
        vm.prank(OWNER);
        house.revokeModule(address(escrow));
        // timed release by a stranger, not only the buyer's confirm, takes the fallback path
        vm.warp(block.timestamp + 72 hours);
        vm.prank(address(0xD00D));
        escrow.release(e);
        assertEq(p.ownerOf(e), BOB);
        assertEq(p.wrappedKey(), "rewrapped");
        assertEq(p.keyHolder(), BOB);
        assertEq(escrow.refunds(ALICE), 2 ether);
        assertEq(address(escrow).balance, 2 ether);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), artistBefore, "no royalty while revoked");
        assertEq(house.balances(ALICE, ETH), 0);
        // re-approving the escrow afterwards does not move the held price into the ledger
        vm.prank(OWNER);
        house.approveModule(address(escrow), artifactsCollection);
        assertEq(escrow.refunds(ALICE), 2 ether);
        uint256 bal = ALICE.balance;
        vm.prank(ALICE);
        escrow.withdrawRefund();
        assertEq(ALICE.balance - bal, 2 ether);
        assertEq(address(escrow).balance, 0);
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NoRefund.selector);
        escrow.withdrawRefund();
        // the listing is gone: nothing can be released twice
        vm.expectRevert(ArtifactsEscrow.NotListed.selector);
        escrow.release(e);
        // the new owner trades normally once the module is back
        vm.prank(BOB);
        escrow.list(e, 1 ether);
        vm.prank(ALICE);
        escrow.buy{value: 1 ether}(e, bytes32(uint256(2)));
        vm.prank(BOB);
        escrow.postKey(e, "for-alice");
        vm.prank(ALICE);
        escrow.confirm(e);
        assertEq(house.balances(ARTIST_PAYOUT, ETH), artistBefore + 0.075 ether);
        assertEq(house.balances(BOB, ETH), 0.925 ether);
        assertEq(p.ownerOf(e), ALICE);
    }

    function test_cancelRestoresTheSellersOwnKeyOnlyIfItHadOne() public {
        configureAndOpenSale(1 ether);
        uint16 e = buyAndAssign(ALICE, address(0), 3);
        ArtifactsPiece p = claimPiece(e, ALICE);
        bytes memory original = p.wrappedKey();
        assertGt(original.length, 0);
        vm.prank(ALICE);
        escrow.list(e, 1 ether);
        vm.prank(BOB);
        escrow.buy{value: 1 ether}(e, bytes32(uint256(1)));
        assertEq(p.wrappedKey().length, 0, "the key is cleared while in escrow");
        assertEq(p.keyHolder(), address(escrow));
        vm.prank(BOB);
        escrow.cancel(e);
        assertEq(p.ownerOf(e), ALICE);
        assertEq(p.wrappedKey(), original);
        assertEq(p.keyHolder(), ALICE);
        assertEq(p.transferCount(), 2);
        assertEq(escrow.refunds(BOB), 1 ether);
        // a cancelled resale leaves no listing and nothing for the seller to pull
        assertEq(escrow.listing(e).seller, address(0));
        assertEq(escrow.refunds(ALICE), 0);

        // a seller holding the piece without any key gets none back
        vm.prank(ALICE);
        p.transferFrom(ALICE, BOB, e);
        assertEq(p.wrappedKey().length, 0);
        vm.prank(BOB);
        escrow.list(e, 1 ether);
        vm.deal(address(0xC0), 1 ether);
        vm.prank(address(0xC0));
        escrow.buy{value: 1 ether}(e, bytes32(uint256(2)));
        vm.prank(address(0xC0));
        escrow.cancel(e);
        assertEq(p.ownerOf(e), BOB);
        assertEq(p.wrappedKey().length, 0);
        // the escrow is now the previous holder; ALICE, two transfers back, may no longer post for BOB
        assertEq(p.previousOwner(), address(escrow));
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsPiece.NotKeyPoster.selector);
        p.setWrappedKey("alice-late");
        vm.prank(address(escrow));
        p.setWrappedKey("escrow-rewrap");
        assertEq(p.wrappedKey(), "escrow-rewrap");
        assertEq(address(escrow).balance, 2 ether);
        assertEq(escrow.refunds(BOB) + escrow.refunds(address(0xC0)), 2 ether);
    }

    function test_selfTransferKeepsTheKeyButKillsTheListing() public {
        configureAndOpenSale(1 ether);
        uint16 e = buyAndAssign(ALICE, address(0), 3);
        ArtifactsPiece p = claimPiece(e, ALICE);
        bytes memory original = p.wrappedKey();
        vm.prank(ALICE);
        escrow.list(e, 1 ether);
        vm.prank(ALICE);
        p.transferFrom(ALICE, ALICE, e);
        assertEq(p.wrappedKey(), original, "a self-transfer is not a change of holder");
        assertEq(p.transferCount(), 1);
        assertEq(p.previousOwner(), address(0));
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.ListingStale.selector);
        escrow.buy{value: 1 ether}(e, bytes32(uint256(1)));
        assertEq(address(escrow).balance, 0);
        // the stale listing can still be withdrawn or replaced by the seller
        vm.prank(ALICE);
        escrow.cancelListing(e);
        vm.prank(ALICE);
        escrow.list(e, 1 ether);
        assertEq(escrow.listing(e).epoch, 1);
        vm.prank(BOB);
        escrow.buy{value: 1 ether}(e, bytes32(uint256(1)));
        assertEq(p.ownerOf(e), address(escrow));
    }

    function test_oldOwnersListingCannotSellTheNewOwnersPiece() public {
        configureAndOpenSale(1 ether);
        uint16 e = buyAndAssign(ALICE, address(0), 3);
        ArtifactsPiece p = claimPiece(e, ALICE);
        vm.prank(ALICE);
        escrow.list(e, 1 wei);
        vm.prank(ALICE);
        p.transferFrom(ALICE, BOB, e);
        // the stale 1 wei listing by ALICE cannot take BOB's piece
        vm.deal(address(0xC0), 1 ether);
        vm.prank(address(0xC0));
        vm.expectRevert(ArtifactsEscrow.NotPieceOwner.selector);
        escrow.buy{value: 1 wei}(e, bytes32(uint256(1)));
        // BOB cannot cancel ALICE's listing but can replace it with its own
        vm.prank(BOB);
        vm.expectRevert(ArtifactsEscrow.NotSeller.selector);
        escrow.cancelListing(e);
        vm.prank(BOB);
        escrow.list(e, 5 ether);
        assertEq(escrow.listing(e).seller, BOB);
        assertEq(escrow.listing(e).price, 5 ether);
        vm.prank(address(0xC0));
        vm.expectRevert(ArtifactsEscrow.WrongPayment.selector);
        escrow.buy{value: 1 wei}(e, bytes32(uint256(1)));
        // ALICE's old listing is gone, so ALICE can no longer cancel it either
        vm.prank(ALICE);
        vm.expectRevert(ArtifactsEscrow.NotSeller.selector);
        escrow.cancelListing(e);
    }

    function test_escrowRefundIsNonReentrant() public {
        configureAndOpenSale(1 ether);
        uint16 e = buyAndAssign(ALICE, address(0), 3);
        claimPiece(e, ALICE);
        EscrowReenterer r = new EscrowReenterer(escrow);
        vm.prank(ALICE);
        escrow.list(e, 1 ether);
        r.buy{value: 1 ether}(e);
        r.cancel(e);
        assertEq(escrow.refunds(address(r)), 1 ether);
        r.pull();
        assertFalse(r.reentered());
        assertEq(address(r).balance, 1 ether);
        assertEq(escrow.refunds(address(r)), 0);
        assertEq(address(escrow).balance, 0);
    }
}
