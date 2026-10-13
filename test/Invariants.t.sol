// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./Fixture.sol";
import {ArtHouse} from "../src/ArtHouse.sol";
import {ArtCollection} from "../src/ArtCollection.sol";
import {ArtifactsPiece} from "../src/ArtifactsPiece.sol";
import {ArtifactsSale} from "../src/ArtifactsSale.sol";
import {ArtifactsAuction} from "../src/ArtifactsAuction.sol";
import {ArtifactsEscrow} from "../src/ArtifactsEscrow.sol";
import {ArtifactsFactory} from "../src/ArtifactsFactory.sol";
import {MockIMD, MockVRFCoordinator} from "./mocks/Mocks.sol";

address constant CAROL = address(0xCA201);
address constant DAVE = address(0xDA7E);

// =====================================================================================================================
// ArtHouse ledger
// =====================================================================================================================

contract LedgerHandler is Test {
    ArtHouse internal house;
    MockIMD internal imd;
    address internal owner;
    address internal artist;
    uint256 internal col;
    uint256 internal modCol;
    uint256 internal pieceCount;

    address[] public actors;
    uint256 public nextPiece = 1;

    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public imdIn;
    uint256 public imdOut;

    constructor(
        ArtHouse house_,
        MockIMD imd_,
        address owner_,
        address artist_,
        uint256 col_,
        uint256 modCol_,
        uint256 pieceCount_,
        address[] memory actors_
    ) {
        house = house_;
        imd = imd_;
        owner = owner_;
        artist = artist_;
        col = col_;
        modCol = modCol_;
        pieceCount = pieceCount_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev The broker argument is sometimes zero, sometimes the buyer, sometimes an unapproved actor.
    function _broker(uint256 seed) internal view returns (address) {
        if (seed % 7 == 0) return address(0);
        return _actor(seed / 7);
    }

    function mintEth(uint256 buyerSeed, uint256 brokerSeed) external {
        if (nextPiece > pieceCount) return;
        uint256 price = house.collection(col).priceEth;
        address buyer = _actor(buyerSeed);
        vm.deal(buyer, buyer.balance + price);
        vm.prank(buyer);
        house.mint{value: price}(col, nextPiece, _broker(brokerSeed));
        nextPiece++;
        ethIn += price;
    }

    function mintImd(uint256 buyerSeed, uint256 brokerSeed) external {
        if (nextPiece > pieceCount) return;
        uint256 price = house.collection(col).priceImd;
        address buyer = _actor(buyerSeed);
        imd.mint(buyer, price);
        vm.startPrank(buyer);
        imd.approve(address(house), price);
        house.mintWithIMD(col, nextPiece, _broker(brokerSeed), price);
        vm.stopPrank();
        nextPiece++;
        imdIn += price;
    }

    /// @dev This handler is an approved sale module for `modCol` and records ETH sales through the ledger.
    function recordSale(uint256 amount, uint256 buyerSeed, uint256 brokerSeed) external {
        amount = bound(amount, 1, 50 ether);
        address buyer = _actor(buyerSeed);
        address broker = _broker(brokerSeed);
        ArtHouse.Collection memory c = house.collection(modCol);
        address payout = house.royaltyReceiver(modCol);
        uint256 houseBefore = house.balances(address(house), address(0));
        uint256 payoutBefore = house.balances(payout, address(0));
        uint256 brokerBefore = house.balances(broker, address(0));
        vm.deal(address(this), amount);
        house.recordSale{value: amount}(buyer, broker);
        ethIn += amount;

        bool earns = broker != address(0) && broker != buyer && house.isBroker(broker);
        uint256 brokerShare = earns ? amount * c.brokerBps / 10_000 : 0;
        uint256 artistShare = amount * c.artistBps / 10_000;
        if (broker != payout && broker != address(0)) {
            assertEq(house.balances(broker, address(0)) - brokerBefore, brokerShare, "broker share");
            assertEq(house.balances(payout, address(0)) - payoutBefore, artistShare, "artist share");
        }
        assertEq(
            house.balances(address(house), address(0)) - houseBefore,
            amount - (amount * c.brokerBps / 10_000) - artistShare + (earns ? 0 : amount * c.brokerBps / 10_000),
            "house share incl. rounding"
        );
    }

    function recordResale(uint256 amount, uint256 sellerSeed) external {
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(this), amount);
        house.recordResale{value: amount}(_actor(sellerSeed));
        ethIn += amount;
    }

    function withdraw(uint256 actorSeed, bool eth) external {
        address a = _actor(actorSeed);
        address currency = eth ? address(0) : address(imd);
        uint256 owed = house.balances(a, currency);
        if (owed == 0) return;
        uint256 before = eth ? a.balance : imd.balanceOf(a);
        vm.prank(a);
        house.withdraw(currency);
        uint256 got = (eth ? a.balance : imd.balanceOf(a)) - before;
        assertEq(got, owed, "withdraw pays exactly what is owed");
        assertEq(house.balances(a, currency), 0);
        if (eth) ethOut += owed;
        else imdOut += owed;
    }

    function withdrawHouse(bool eth) external {
        address currency = eth ? address(0) : address(imd);
        uint256 owed = house.balances(address(house), currency);
        if (owed == 0) return;
        vm.prank(owner);
        house.withdrawHouse(currency);
        if (eth) ethOut += owed;
        else imdOut += owed;
    }

    function setSplit(uint16 brokerBps, uint16 houseBps) external {
        brokerBps = uint16(bound(brokerBps, 0, 10_000));
        houseBps = uint16(bound(houseBps, 0, 10_000 - brokerBps));
        vm.startPrank(owner);
        house.setSplit(col, brokerBps, houseBps, 10_000 - brokerBps - houseBps);
        house.setSplit(modCol, brokerBps, houseBps, 10_000 - brokerBps - houseBps);
        vm.stopPrank();
    }

    function toggleBroker(uint256 seed) external {
        address b = _actor(seed);
        vm.prank(owner);
        if (house.isBroker(b)) house.revokeBroker(b);
        else house.approveBroker(b);
    }

    function setPayout(uint256 seed) external {
        vm.prank(artist);
        house.setPayout(_actor(seed));
    }

    function setPrices(uint128 eth, uint128 imdPrice) external {
        eth = uint128(bound(eth, 1, 10 ether));
        imdPrice = uint128(bound(imdPrice, 1, 1_000_000 ether));
        vm.startPrank(owner);
        house.closeSale(col);
        house.setPrices(col, eth, imdPrice);
        house.openSale(col);
        vm.stopPrank();
    }

    receive() external payable {}
}

contract ArtHouseLedgerInvariantTest is Fixture {
    LedgerHandler internal handler;
    ArtCollection internal token;
    uint256 internal col;
    uint256 internal constant PIECES = 40;
    bytes internal constant SVG = '<svg xmlns="http://www.w3.org/2000/svg"/>';
    address[] internal actorList;

    function setUp() public override {
        super.setUp();
        vm.startPrank(OWNER);
        address tk;
        (col, tk) = house.createCollection(ARTIST, "Later", "LATER");
        token = ArtCollection(tk);
        for (uint256 i = 1; i <= PIECES; ++i) {
            house.registerPiece(col, i, keccak256(SVG), "P", "D");
            house.uploadChunk(col, i, 0, SVG);
            house.finalizePiece(col, i);
        }
        house.seal(col);
        house.setPrices(col, 0.1 ether, 1000 ether);
        house.openSale(col);
        vm.stopPrank();

        actorList.push(ALICE);
        actorList.push(BOB);
        actorList.push(BROKER);
        actorList.push(ARTIST_PAYOUT);
        actorList.push(CAROL);
        handler = new LedgerHandler(house, imd, OWNER, ARTIST, col, artifactsCollection, PIECES, actorList);
        vm.prank(OWNER);
        house.approveModule(address(handler), artifactsCollection);
        targetContract(address(handler));
    }

    function _sumOwed(address currency) internal view returns (uint256 sum) {
        for (uint256 i; i < actorList.length; ++i) {
            sum += house.balances(actorList[i], currency);
        }
        sum += house.balances(address(house), currency);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_ethHeldEqualsEthOwed() public view {
        assertEq(address(house).balance, _sumOwed(address(0)));
        assertEq(address(house).balance, handler.ethIn() - handler.ethOut());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_imdHeldEqualsImdOwed() public view {
        assertEq(imd.balanceOf(address(house)), _sumOwed(address(imd)));
        assertEq(imd.balanceOf(address(house)), handler.imdIn() - handler.imdOut());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_oneTokenPerPaidMintAndNeverAboveRegistered() public view {
        uint256 minted = handler.nextPiece() - 1;
        uint256 held;
        for (uint256 i; i < actorList.length; ++i) {
            held += token.balanceOf(actorList[i]);
        }
        assertEq(held, minted);
        assertLe(minted, token.maxSupply());
        assertEq(token.maxSupply(), PIECES);
    }
}

// =====================================================================================================================
// THE SOURCE auction
// =====================================================================================================================

contract AuctionHandler is Test {
    ArtifactsAuction internal auction;
    address[] internal actors;
    uint256 public ethIn;
    uint256 public ethOut;
    uint256 public paidToHouse;
    uint64 public lastEnd;
    bool public everSettled;

    constructor(ArtifactsAuction auction_, address[] memory actors_) {
        auction = auction_;
        actors = actors_;
        lastEnd = auction_.endTime();
    }

    function bid(uint256 actorSeed, uint256 extra, bool tooLow) external {
        if (auction.settled() || block.timestamp >= auction.endTime()) return;
        address a = actors[actorSeed % actors.length];
        uint256 min = auction.minimumBid();
        if (tooLow) {
            // anything below the minimum must revert and change nothing
            uint256 low = bound(extra, 0, min - 1);
            address highBefore = auction.highBidder();
            vm.deal(a, a.balance + low);
            vm.prank(a);
            try auction.bid{value: low}() {
                revert("bid below minimum accepted");
            } catch {}
            assertEq(auction.highBidder(), highBefore);
            return;
        }
        uint256 amount = min + bound(extra, 0, 3 ether);
        vm.deal(a, a.balance + amount);
        uint256 prevHigh = auction.highBid();
        vm.prank(a);
        auction.bid{value: amount}();
        ethIn += amount;
        // bids here are at least 1 ether, so the 5% step is never lost to rounding (see .imd-findings.json)
        if (prevHigh != 0) assertGe(amount * 10_000, prevHigh * 10_500 - 10_000);
        uint64 end = auction.endTime();
        assertGe(end, lastEnd, "end never moves earlier");
        assertGe(end, block.timestamp + 10 minutes, "a bid always leaves at least ten minutes");
        lastEnd = end;
    }

    function withdrawRefund(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        uint256 r = auction.refunds(a);
        if (r == 0) return;
        uint256 before = a.balance;
        vm.prank(a);
        auction.withdrawRefund();
        assertEq(a.balance - before, r);
        ethOut += r;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 6 hours));
    }

    function settle() external {
        if (auction.settled() || block.timestamp < auction.endTime() || auction.highBidder() == address(0)) return;
        auction.settle();
        paidToHouse += auction.highBid();
        everSettled = true;
    }
}

contract AuctionInvariantTest is Fixture {
    AuctionHandler internal handler;
    address[] internal actorList;

    function setUp() public override {
        super.setUp();
        uploadAllPieces();
        vm.prank(OWNER);
        auction.configure(1 ether, uint64(block.timestamp + 1 days));
        actorList.push(ALICE);
        actorList.push(BOB);
        actorList.push(CAROL);
        actorList.push(DAVE);
        handler = new AuctionHandler(auction, actorList);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_auctionHoldsExactlyRefundsPlusOpenHighBid() public view {
        uint256 owed;
        for (uint256 i; i < actorList.length; ++i) {
            owed += auction.refunds(actorList[i]);
        }
        if (!auction.settled()) owed += auction.highBid();
        assertEq(address(auction).balance, owed);
        assertEq(handler.ethIn(), address(auction).balance + handler.ethOut() + handler.paidToHouse());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_settlementIsFinalAndAssignsTheWinner() public view {
        if (handler.everSettled()) assertTrue(auction.settled());
        if (auction.settled()) {
            assertEq(factory.assignedTo(256), auction.highBidder());
            assertEq(house.balances(address(house), ETH) + house.balances(ARTIST_PAYOUT, ETH), auction.highBid());
            assertEq(address(house).balance, auction.highBid());
        } else {
            assertEq(factory.assignedTo(256), address(0));
            assertEq(address(house).balance, 0);
        }
        if (auction.highBidder() != address(0)) assertGe(auction.highBid(), auction.reserve());
    }
}

// =====================================================================================================================
// Resale escrow
// =====================================================================================================================

contract EscrowHandler is Test {
    ArtifactsEscrow internal escrow;
    ArtifactsFactory internal factory;
    address[] internal actors;
    uint16[] internal ids;

    uint256 public ethIn;
    uint256 public refundsOut;
    uint256 public released;

    constructor(ArtifactsEscrow escrow_, ArtifactsFactory factory_, address[] memory actors_, uint16[] memory ids_) {
        escrow = escrow_;
        factory = factory_;
        actors = actors_;
        ids = ids_;
    }

    function _id(uint256 seed) internal view returns (uint16) {
        return ids[seed % ids.length];
    }

    function _piece(uint16 id) internal view returns (ArtifactsPiece) {
        return ArtifactsPiece(factory.pieceContract(id));
    }

    function list(uint256 seed, uint256 price) external {
        uint16 id = _id(seed);
        address owner = _piece(id).ownerOf(id);
        if (owner == address(escrow)) return;
        vm.prank(owner);
        escrow.list(id, bound(price, 1, 20 ether));
    }

    function buy(uint256 seed, uint256 buyerSeed) external {
        uint16 id = _id(seed);
        ArtifactsEscrow.Listing memory l = escrow.listing(id);
        if (l.seller == address(0) || l.buyer != address(0)) return;
        if (_piece(id).ownerOf(id) != l.seller) return;
        address b = actors[buyerSeed % actors.length];
        if (b == l.seller) return;
        vm.deal(b, b.balance + l.price);
        vm.prank(b);
        escrow.buy{value: l.price}(id, keccak256(abi.encode(b)));
        ethIn += l.price;
        assertEq(_piece(id).ownerOf(id), address(escrow));
    }

    function postKey(uint256 seed) external {
        uint16 id = _id(seed);
        ArtifactsEscrow.Listing memory l = escrow.listing(id);
        if (l.buyer == address(0) || l.keyPostedAt != 0) return;
        vm.prank(l.seller);
        escrow.postKey(id, abi.encodePacked("key-for-", l.buyer));
    }

    function cancel(uint256 seed) external {
        uint16 id = _id(seed);
        ArtifactsEscrow.Listing memory l = escrow.listing(id);
        if (l.buyer == address(0) || l.keyPostedAt != 0) return;
        vm.prank(l.buyer);
        escrow.cancel(id);
        assertEq(_piece(id).ownerOf(id), l.seller);
    }

    function confirmOrRelease(uint256 seed, bool byTime, uint256 dt) external {
        uint16 id = _id(seed);
        ArtifactsEscrow.Listing memory l = escrow.listing(id);
        if (l.buyer == address(0) || l.keyPostedAt == 0) return;
        if (byTime) {
            vm.warp(block.timestamp + bound(dt, 0, 4 days));
            if (block.timestamp < l.keyPostedAt + 72 hours) {
                vm.expectRevert(ArtifactsEscrow.TooEarly.selector);
                escrow.release(id);
                return;
            }
            escrow.release(id);
        } else {
            vm.prank(l.buyer);
            escrow.confirm(id);
        }
        released += l.price;
        ArtifactsPiece p = _piece(id);
        assertEq(p.ownerOf(id), l.buyer);
        assertEq(p.keyHolder(), l.buyer);
        assertEq(p.wrappedKey(), l.wrappedKey);
    }

    function withdrawRefund(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        uint256 r = escrow.refunds(a);
        if (r == 0) return;
        vm.prank(a);
        escrow.withdrawRefund();
        refundsOut += r;
    }

    function plainTransfer(uint256 seed, uint256 toSeed) external {
        uint16 id = _id(seed);
        ArtifactsPiece p = _piece(id);
        address owner = p.ownerOf(id);
        if (owner == address(escrow)) return;
        address to = actors[toSeed % actors.length];
        vm.prank(owner);
        p.transferFrom(owner, to, id);
    }
}

contract EscrowInvariantTest is Fixture {
    EscrowHandler internal handler;
    address[] internal actorList;
    uint16[] internal ids;

    function setUp() public override {
        super.setUp();
        uploadAllPieces();
        configureAndOpenSale(1 ether);
        actorList.push(ALICE);
        actorList.push(BOB);
        actorList.push(CAROL);
        actorList.push(DAVE);
        vm.deal(CAROL, 100 ether);
        for (uint256 i; i < 3; ++i) {
            uint16 e = buyAndAssign(actorList[i], address(0), uint256(keccak256(abi.encode(i))));
            claimPiece(e, actorList[i]);
            ids.push(e);
        }
        handler = new EscrowHandler(escrow, factory, actorList, ids);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_escrowHoldsRefundsPlusFundedListings() public view {
        uint256 owed;
        for (uint256 i; i < actorList.length; ++i) {
            owed += escrow.refunds(actorList[i]);
        }
        for (uint256 i; i < ids.length; ++i) {
            ArtifactsEscrow.Listing memory l = escrow.listing(ids[i]);
            ArtifactsPiece p = ArtifactsPiece(factory.pieceContract(ids[i]));
            if (l.buyer != address(0)) {
                owed += l.price;
                assertEq(p.ownerOf(ids[i]), address(escrow), "funded piece is held");
            } else {
                assertTrue(p.ownerOf(ids[i]) != address(escrow), "unfunded piece is not held");
            }
            assertEq(p.balanceOf(p.ownerOf(ids[i])), 1, "exactly one token per piece contract");
        }
        assertEq(address(escrow).balance, owed);
        assertEq(handler.ethIn(), address(escrow).balance + handler.refundsOut() + handler.released());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_ledgerHoldsWhatItOwes() public view {
        uint256 owed = house.balances(address(house), ETH) + house.balances(ARTIST_PAYOUT, ETH);
        for (uint256 i; i < actorList.length; ++i) {
            owed += house.balances(actorList[i], ETH);
        }
        assertEq(address(house).balance, owed);
        // primary sales (3 ether) plus every released resale
        assertEq(address(house).balance, 3 ether + handler.released());
    }
}

// =====================================================================================================================
// Edition sale and VRF assignment
// =====================================================================================================================

contract SaleHandler is Test {
    ArtifactsSale internal sale;
    ArtifactsFactory internal factory;
    MockVRFCoordinator internal vrf;
    address[] internal actors;
    address internal broker;

    uint256[] internal pending;
    mapping(uint16 => uint256) public timesAssigned;
    uint16[] public assignedEditions;
    uint256 public paid;

    constructor(
        ArtifactsSale sale_,
        ArtifactsFactory factory_,
        MockVRFCoordinator vrf_,
        address[] memory actors_,
        address broker_
    ) {
        sale = sale_;
        factory = factory_;
        vrf = vrf_;
        actors = actors_;
        broker = broker_;
    }

    function assignedLength() external view returns (uint256) {
        return assignedEditions.length;
    }

    function buy(uint256 actorSeed, bool withBroker) external {
        if (sale.purchaseCount() >= 255) return;
        address a = actors[actorSeed % actors.length];
        uint256 price = sale.price();
        vm.deal(a, a.balance + price);
        vm.prank(a);
        pending.push(sale.buy{value: price}(withBroker ? broker : address(0)));
        paid += price;
    }

    function fulfil(uint256 pick, uint256 word) external {
        if (pending.length == 0) return;
        uint256 i = pick % pending.length;
        uint256 purchaseId = pending[i];
        pending[i] = pending[pending.length - 1];
        pending.pop();
        ArtifactsSale.Purchase memory p = sale.purchase(purchaseId);
        vrf.fulfill(p.requestId, word);
        uint16 e = sale.purchase(purchaseId).edition;
        assertTrue(e >= 1 && e <= 255, "edition in range");
        timesAssigned[e] += 1;
        assignedEditions.push(e);
        assertEq(factory.assignedTo(e), p.buyer);
        // a repeated callback for the same request changes nothing
        vrf.fulfill(p.requestId, word ^ 1);
        assertEq(sale.purchase(purchaseId).edition, e);
    }

    function repriceWhileClosed(uint256 price) external {
        address owner = sale.owner();
        vm.startPrank(owner);
        sale.closeSale();
        sale.setPrice(bound(price, 1, 5 ether));
        sale.openSale();
        vm.stopPrank();
    }
}

contract SaleInvariantTest is Fixture {
    SaleHandler internal handler;
    address[] internal actorList;

    function setUp() public override {
        super.setUp();
        uploadAllPieces();
        configureAndOpenSale(0.5 ether);
        actorList.push(ALICE);
        actorList.push(BOB);
        actorList.push(CAROL);
        handler = new SaleHandler(sale, factory, vrf, actorList, BROKER);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    function invariant_noEditionAssignedTwice() public view {
        uint256 n = handler.assignedLength();
        assertEq(sale.assignedCount(), n);
        assertLe(sale.assignedCount(), sale.purchaseCount());
        assertLe(sale.purchaseCount(), 255);
        for (uint256 i; i < n; ++i) {
            assertEq(handler.timesAssigned(handler.assignedEditions(i)), 1);
        }
        assertEq(factory.assignedTo(256), address(0), "THE SOURCE is never sold as an edition");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    function invariant_saleForwardsEveryWeiToLedger() public view {
        assertEq(address(sale).balance, 0);
        assertEq(address(house).balance, handler.paid());
        uint256 owed =
            house.balances(address(house), ETH) + house.balances(ARTIST_PAYOUT, ETH) + house.balances(BROKER, ETH);
        assertEq(address(house).balance, owed);
    }
}
