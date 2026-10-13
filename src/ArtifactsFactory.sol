// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HouseOwnable} from "./HouseOwnable.sol";
import {ArtifactsSeal, Traits} from "./libraries/ArtifactsSeal.sol";
import {SSTORE2} from "./libraries/SSTORE2.sol";
import {IArtHouseLedger, IArtifactsPiece} from "./interfaces/IArtifactsFactory.sol";

/// @title ArtifactsFactory
/// @notice The ARTIFACTS registry. Before the sale the curator uploads every piece's public traits, ciphertext
///         (SSTORE2) and content-key commitment, then locks them forever. Sale modules (ArtifactsSale for the 255
///         editions, ArtifactsAuction for THE SOURCE) assign pieces to buyers; the buyer registers an X25519 viewing
///         key, the curator posts the content key wrapped to it, and the buyer's claim deploys the piece's own
///         contract as an EIP-1167 clone of ArtifactsPiece.
contract ArtifactsFactory is HouseOwnable, ReentrancyGuard {
    struct PieceData {
        Traits traits;
        address ciphertext;
        bytes32 commitment;
        bool set;
    }

    uint16 public constant PIECE_COUNT = 256;
    uint16 public constant EDITION_COUNT = 255;
    uint16 public constant SOURCE_ID = 256;

    IArtHouseLedger public immutable house;
    address public immutable pieceImplementation;

    address public sale;
    address public auction;
    address public escrow;

    mapping(uint16 => PieceData) internal _pieces;
    uint16 public piecesSet;
    bool public locked;

    /// @notice Buyer of a piece between assignment and claim.
    mapping(uint16 => address) public assignedTo;
    mapping(uint16 => address) public pieceContract;
    mapping(address => bytes32) public viewingKey;
    /// @notice Content key wrapped by the curator to the assigned buyer's viewing key, waiting for the claim.
    mapping(uint16 => bytes) public pendingWrappedKey;

    event PieceSet(uint16 indexed pieceId, address ciphertext, bytes32 commitment);
    event Locked();
    event ModulesSet(address sale, address auction, address escrow);
    event Assigned(uint16 indexed pieceId, address indexed to);
    event ViewingKeyRegistered(address indexed account, bytes32 viewingPublicKey);
    event ContentKeyPosted(uint16 indexed pieceId, address indexed to);
    event Claimed(uint16 indexed pieceId, address indexed owner, address piece);

    error ZeroAddress();
    error InvalidPieceId();
    error AlreadyLocked();
    error NotLocked();
    error PiecesMissing(uint16 set);
    error EmptyCiphertext();
    error EmptyTraits();
    error ModulesAlreadySet();
    error ModulesNotSet();
    error NotSale();
    error NotAuction();
    error NotEscrow();
    error AlreadyAssigned();
    error NotAssignedBuyer();
    error AlreadyClaimed();
    error NoViewingKey();
    error NoWrappedKey();
    error EmptyKey();

    constructor(address owner_, address house_, address pieceImplementation_) HouseOwnable(owner_) {
        if (house_ == address(0) || pieceImplementation_ == address(0)) revert ZeroAddress();
        house = IArtHouseLedger(house_);
        pieceImplementation = pieceImplementation_;
    }

    // ---------------------------------------------------------------- curation (before lock)

    /// @notice Uploads one piece: public traits, AES-256-GCM ciphertext of its seed and keccak256 of its content key.
    function setPiece(uint16 pieceId, Traits calldata traits, bytes calldata ciphertext, bytes32 commitment)
        external
        onlyOwner
    {
        if (locked) revert AlreadyLocked();
        if (pieceId == 0 || pieceId > PIECE_COUNT) revert InvalidPieceId();
        if (ciphertext.length == 0) revert EmptyCiphertext();
        if (bytes(traits.title).length == 0 || bytes(traits.palette).length == 0 || bytes(traits.direction).length == 0)
        {
            revert EmptyTraits();
        }
        PieceData storage p = _pieces[pieceId];
        if (!p.set) {
            p.set = true;
            piecesSet += 1;
        }
        p.traits = traits;
        p.ciphertext = SSTORE2.write(ciphertext);
        p.commitment = commitment;
        emit PieceSet(pieceId, p.ciphertext, commitment);
    }

    /// @notice Locks every piece forever. Requires all 256 pieces to be set.
    function lock() external onlyOwner {
        if (locked) revert AlreadyLocked();
        if (piecesSet != PIECE_COUNT) revert PiecesMissing(piecesSet);
        locked = true;
        emit Locked();
    }

    /// @notice One-time wiring of the sale, auction and escrow contracts deployed after this factory.
    function setModules(address sale_, address auction_, address escrow_) external onlyOwner {
        if (sale != address(0)) revert ModulesAlreadySet();
        if (sale_ == address(0) || auction_ == address(0) || escrow_ == address(0)) revert ZeroAddress();
        sale = sale_;
        auction = auction_;
        escrow = escrow_;
        emit ModulesSet(sale_, auction_, escrow_);
    }

    // ---------------------------------------------------------------- assignment (modules)

    function assignEdition(uint16 pieceId, address to) external {
        if (sale == address(0)) revert ModulesNotSet();
        if (msg.sender != sale) revert NotSale();
        if (pieceId == 0 || pieceId > EDITION_COUNT) revert InvalidPieceId();
        _assign(pieceId, to);
    }

    function assignSource(address to) external {
        if (auction == address(0)) revert ModulesNotSet();
        if (msg.sender != auction) revert NotAuction();
        _assign(SOURCE_ID, to);
    }

    function _assign(uint16 pieceId, address to) internal {
        if (!locked) revert NotLocked();
        if (to == address(0)) revert ZeroAddress();
        if (assignedTo[pieceId] != address(0)) revert AlreadyAssigned();
        assignedTo[pieceId] = to;
        emit Assigned(pieceId, to);
    }

    // ---------------------------------------------------------------- keys and claim

    /// @notice Registers the caller's X25519 viewing public key (R13). Can be replaced at any time.
    function registerViewingKey(bytes32 viewingPublicKey) external {
        _registerViewingKey(msg.sender, viewingPublicKey);
    }

    /// @notice The escrow registers the buyer's viewing key as part of a resale payment.
    function registerViewingKeyFor(address account, bytes32 viewingPublicKey) external {
        if (escrow == address(0)) revert ModulesNotSet();
        if (msg.sender != escrow) revert NotEscrow();
        _registerViewingKey(account, viewingPublicKey);
    }

    function _registerViewingKey(address account, bytes32 viewingPublicKey) internal {
        if (viewingPublicKey == bytes32(0)) revert EmptyKey();
        viewingKey[account] = viewingPublicKey;
        emit ViewingKeyRegistered(account, viewingPublicKey);
    }

    /// @notice The curator posts the content key of an assigned, unclaimed piece wrapped to its buyer's viewing key.
    function postContentKey(uint16 pieceId, bytes calldata wrapped) external onlyOwner {
        address buyer = assignedTo[pieceId];
        if (buyer == address(0)) revert NotAssignedBuyer();
        if (pieceContract[pieceId] != address(0)) revert AlreadyClaimed();
        if (viewingKey[buyer] == bytes32(0)) revert NoViewingKey();
        if (wrapped.length == 0) revert EmptyKey();
        pendingWrappedKey[pieceId] = wrapped;
        emit ContentKeyPosted(pieceId, buyer);
    }

    /// @notice The buyer deploys its piece: a clone of ArtifactsPiece minted to the buyer with the wrapped key.
    function claim(uint16 pieceId) external nonReentrant returns (address piece) {
        if (assignedTo[pieceId] != msg.sender) revert NotAssignedBuyer();
        if (pieceContract[pieceId] != address(0)) revert AlreadyClaimed();
        bytes memory wrapped = pendingWrappedKey[pieceId];
        if (wrapped.length == 0) revert NoWrappedKey();
        delete pendingWrappedKey[pieceId];
        piece = Clones.clone(pieceImplementation);
        pieceContract[pieceId] = piece;
        emit Claimed(pieceId, msg.sender, piece);
        IArtifactsPiece(piece).initialize(pieceId, msg.sender, wrapped);
    }

    // ---------------------------------------------------------------- views

    function pieceInfo(uint16 pieceId)
        external
        view
        returns (Traits memory traits, address ciphertext, bytes32 commitment)
    {
        PieceData storage p = _pieces[pieceId];
        if (!p.set) revert InvalidPieceId();
        return (p.traits, p.ciphertext, p.commitment);
    }

    function ciphertextBytes(uint16 pieceId) external view returns (bytes memory) {
        PieceData storage p = _pieces[pieceId];
        if (!p.set) revert InvalidPieceId();
        return SSTORE2.read(p.ciphertext);
    }

    /// @notice The seal metadata of any set piece, identical to what its piece contract serves after the claim.
    function tokenURI(uint16 pieceId) external view returns (string memory) {
        PieceData storage p = _pieces[pieceId];
        if (!p.set) revert InvalidPieceId();
        return ArtifactsSeal.tokenURI(pieceId, p.traits);
    }

    /// @notice ERC-2981 receiver for every ARTIFACTS piece: the artist's payout address in the ArtHouse ledger.
    function royaltyReceiver() external view returns (address) {
        return house.moduleRoyaltyReceiver(address(this));
    }
}
