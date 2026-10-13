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
import {Rejector} from "./mocks/Mocks.sol";
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
        vm.expectRevert(ArtHouse.NotModule.selector);
        house.moduleRoyaltyReceiver(address(sale));
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

    function test_auctionSettleNeedsApprovedModule() public {
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 hours));
        vm.prank(ALICE);
        auction.bid{value: 1 ether}();
        vm.warp(auction.endTime());
        vm.prank(OWNER);
        house.revokeModule(address(auction));
        vm.expectRevert(ArtHouse.NotModule.selector);
        auction.settle();
        assertFalse(auction.settled());
        assertEq(factory.assignedTo(256), address(0));
        vm.prank(OWNER);
        house.approveModule(address(auction), artifactsCollection);
        auction.settle();
        assertEq(factory.assignedTo(256), ALICE);
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
