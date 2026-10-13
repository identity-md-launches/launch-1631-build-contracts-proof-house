// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IArtHouseLedger, IArtifactsFactory, IArtifactsPiece} from "./interfaces/IArtifactsFactory.sol";

/// @title ArtifactsEscrow
/// @notice Keyed resale escrow for ARTIFACTS pieces. The seller lists; the buyer pays the exact price and registers
///         a viewing key; the piece is held here; the seller posts the content key re-wrapped to the buyer; payment
///         releases on the buyer's confirmation or 72 hours after the key is posted; the buyer may cancel until the
///         key is posted. Proceeds go through the ArtHouse ledger (artist royalty, remainder to the seller).
contract ArtifactsEscrow is ReentrancyGuard {
    struct Listing {
        address seller;
        uint256 price;
        address buyer;
        bytes wrappedKey;
        uint64 keyPostedAt;
    }

    uint64 public constant RELEASE_DELAY = 72 hours;

    IArtHouseLedger public immutable house;
    IArtifactsFactory public immutable factory;

    mapping(uint16 pieceId => Listing) internal _listings;
    mapping(address => uint256) public refunds;

    event Listed(uint16 indexed pieceId, address indexed seller, uint256 price);
    event ListingCancelled(uint16 indexed pieceId);
    event Bought(uint16 indexed pieceId, address indexed buyer, uint256 price);
    event KeyPosted(uint16 indexed pieceId);
    event Cancelled(uint16 indexed pieceId, address indexed buyer);
    event Released(uint16 indexed pieceId, address indexed seller, address indexed buyer, uint256 price);
    event RefundWithdrawn(address indexed account, uint256 amount);

    error ZeroAddress();
    error UnknownPiece();
    error NotPieceOwner();
    error NoPrice();
    error ListingFunded();
    error NotListed();
    error NotSeller();
    error NotBuyer();
    error WrongPayment();
    error SellerCannotBuy();
    error KeyAlreadyPosted();
    error KeyNotPosted();
    error EmptyKey();
    error TooEarly();
    error NoRefund();
    error EthTransferFailed();

    constructor(address house_, address factory_) {
        if (house_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        house = IArtHouseLedger(house_);
        factory = IArtifactsFactory(factory_);
    }

    function listing(uint16 pieceId) external view returns (Listing memory) {
        return _listings[pieceId];
    }

    /// @notice Lists a claimed piece at an ETH price. Re-listing while unfunded replaces the price.
    function list(uint16 pieceId, uint256 price) external {
        IArtifactsPiece piece = _piece(pieceId);
        if (piece.ownerOf(pieceId) != msg.sender) revert NotPieceOwner();
        if (price == 0) revert NoPrice();
        Listing storage l = _listings[pieceId];
        if (l.buyer != address(0)) revert ListingFunded();
        l.seller = msg.sender;
        l.price = price;
        emit Listed(pieceId, msg.sender, price);
    }

    function cancelListing(uint16 pieceId) external {
        Listing storage l = _listings[pieceId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotSeller();
        if (l.buyer != address(0)) revert ListingFunded();
        delete _listings[pieceId];
        emit ListingCancelled(pieceId);
    }

    /// @notice Pays exactly the listed price and registers the buyer's viewing key; the piece moves into escrow.
    function buy(uint16 pieceId, bytes32 viewingPublicKey) external payable nonReentrant {
        Listing storage l = _listings[pieceId];
        if (l.seller == address(0)) revert NotListed();
        if (l.buyer != address(0)) revert ListingFunded();
        if (msg.value != l.price) revert WrongPayment();
        if (msg.sender == l.seller) revert SellerCannotBuy();
        IArtifactsPiece piece = _piece(pieceId);
        if (piece.ownerOf(pieceId) != l.seller) revert NotPieceOwner();
        l.buyer = msg.sender;
        emit Bought(pieceId, msg.sender, msg.value);
        factory.registerViewingKeyFor(msg.sender, viewingPublicKey);
        piece.transferFrom(l.seller, address(this), pieceId);
    }

    /// @notice The seller posts the content key re-wrapped to the buyer's viewing key.
    function postKey(uint16 pieceId, bytes calldata wrapped) external {
        Listing storage l = _listings[pieceId];
        if (l.buyer == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotSeller();
        if (l.keyPostedAt != 0) revert KeyAlreadyPosted();
        if (wrapped.length == 0) revert EmptyKey();
        l.wrappedKey = wrapped;
        l.keyPostedAt = uint64(block.timestamp);
        emit KeyPosted(pieceId);
    }

    /// @notice The buyer may cancel until the key is posted: the piece returns to the seller, the payment is refundable.
    function cancel(uint16 pieceId) external nonReentrant {
        Listing memory l = _listings[pieceId];
        if (l.buyer == address(0)) revert NotListed();
        if (l.buyer != msg.sender) revert NotBuyer();
        if (l.keyPostedAt != 0) revert KeyAlreadyPosted();
        delete _listings[pieceId];
        refunds[l.buyer] += l.price;
        emit Cancelled(pieceId, l.buyer);
        _piece(pieceId).transferFrom(address(this), l.seller, pieceId);
    }

    /// @notice The buyer confirms the key opens the piece: payment releases now.
    function confirm(uint16 pieceId) external nonReentrant {
        Listing memory l = _listings[pieceId];
        if (l.buyer == address(0)) revert NotListed();
        if (l.buyer != msg.sender) revert NotBuyer();
        if (l.keyPostedAt == 0) revert KeyNotPosted();
        _release(pieceId, l);
    }

    /// @notice Anyone may release 72 hours after the key was posted.
    function release(uint16 pieceId) external nonReentrant {
        Listing memory l = _listings[pieceId];
        if (l.buyer == address(0)) revert NotListed();
        if (l.keyPostedAt == 0) revert KeyNotPosted();
        if (block.timestamp < l.keyPostedAt + RELEASE_DELAY) revert TooEarly();
        _release(pieceId, l);
    }

    function withdrawRefund() external nonReentrant {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NoRefund();
        refunds[msg.sender] = 0;
        emit RefundWithdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _release(uint16 pieceId, Listing memory l) internal {
        delete _listings[pieceId];
        emit Released(pieceId, l.seller, l.buyer, l.price);
        IArtifactsPiece piece = _piece(pieceId);
        piece.transferFrom(address(this), l.buyer, pieceId);
        piece.setWrappedKey(l.wrappedKey);
        house.recordResale{value: l.price}(l.seller);
    }

    function _piece(uint16 pieceId) internal view returns (IArtifactsPiece piece) {
        address p = factory.pieceContract(pieceId);
        if (p == address(0)) revert UnknownPiece();
        piece = IArtifactsPiece(p);
    }
}
