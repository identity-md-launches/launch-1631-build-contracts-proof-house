// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HouseOwnable} from "./HouseOwnable.sol";
import {SSTORE2} from "./libraries/SSTORE2.sol";

/// @title ArtStorage
/// @notice Keeps the bytes of every plain SVG piece of a Proof House collection in SSTORE2 chunks.
///         Writes are accepted only from ArtHouse, which the owner names once with setHouse.
contract ArtStorage is HouseOwnable {
    struct Piece {
        bytes32 contentHash;
        string title;
        string description;
        address[] chunks;
        uint32 size;
        bool finalized;
    }

    /// @notice Largest piece accepted, in bytes (100 KB).
    uint256 public constant MAX_PIECE_BYTES = 100 * 1024;
    /// @notice Largest single chunk: one SSTORE2 contract holds at most 24 575 bytes (EIP-170 minus the STOP byte).
    uint256 public constant MAX_CHUNK_BYTES = SSTORE2.MAX_DATA_BYTES;

    address public house;
    mapping(uint256 collection => uint256) public pieceCount;
    mapping(uint256 collection => bool) public isSealed;
    mapping(uint256 collection => mapping(uint256 pieceId => Piece)) internal _pieces;

    event HouseSet(address indexed house);
    event PieceRegistered(uint256 indexed collection, uint256 indexed pieceId, bytes32 contentHash, string title);
    event ChunkUploaded(
        uint256 indexed collection, uint256 indexed pieceId, uint256 index, address pointer, uint256 size
    );
    event PieceCleared(uint256 indexed collection, uint256 indexed pieceId);
    event PieceRedescribed(uint256 indexed collection, uint256 indexed pieceId, bytes32 contentHash, string title);
    event PieceDropped(uint256 indexed collection, uint256 indexed pieceId);
    event PieceFinalized(uint256 indexed collection, uint256 indexed pieceId);
    event CollectionSealed(uint256 indexed collection);

    error HouseAlreadySet();
    error ZeroAddress();
    error NotHouse();
    error CollectionSealedAlready();
    error PieceIdNotNext(uint256 expected);
    error UnknownPiece();
    error PieceFinalizedAlready();
    error ChunkIndexNotNext(uint256 expected);
    error EmptyChunk();
    error ChunkTooLarge();
    error PieceTooLarge();
    error SizeMismatch();
    error EmptyPiece();
    error ContentHashMismatch(bytes32 expected, bytes32 actual);
    error PieceNotFinalized(uint256 pieceId);
    error NoPieces();

    constructor(address owner_) HouseOwnable(owner_) {}

    modifier onlyHouse() {
        if (msg.sender != house) revert NotHouse();
        _;
    }

    /// @notice One-time: names the ArtHouse that may write here.
    function setHouse(address house_) external onlyOwner {
        if (house != address(0)) revert HouseAlreadySet();
        if (house_ == address(0)) revert ZeroAddress();
        house = house_;
        emit HouseSet(house_);
    }

    // ---------------------------------------------------------------- writes (ArtHouse only)

    function registerPiece(
        uint256 collection,
        uint256 pieceId,
        bytes32 contentHash,
        string calldata title,
        string calldata description
    ) external onlyHouse {
        if (isSealed[collection]) revert CollectionSealedAlready();
        uint256 expected = pieceCount[collection] + 1;
        if (pieceId != expected) revert PieceIdNotNext(expected);
        pieceCount[collection] = expected;
        Piece storage p = _pieces[collection][pieceId];
        p.contentHash = contentHash;
        p.title = title;
        p.description = description;
        emit PieceRegistered(collection, pieceId, contentHash, title);
    }

    function uploadChunk(uint256 collection, uint256 pieceId, uint256 index, bytes calldata data) external onlyHouse {
        Piece storage p = _piece(collection, pieceId);
        if (p.finalized) revert PieceFinalizedAlready();
        if (index != p.chunks.length) revert ChunkIndexNotNext(p.chunks.length);
        if (data.length == 0) revert EmptyChunk();
        if (data.length > MAX_CHUNK_BYTES) revert ChunkTooLarge();
        uint256 newSize = uint256(p.size) + data.length;
        if (newSize > MAX_PIECE_BYTES) revert PieceTooLarge();
        address pointer = SSTORE2.write(data);
        p.chunks.push(pointer);
        p.size = uint32(newSize);
        emit ChunkUploaded(collection, pieceId, index, pointer, newSize);
    }

    function clearPiece(uint256 collection, uint256 pieceId) external onlyHouse {
        Piece storage p = _piece(collection, pieceId);
        if (p.finalized) revert PieceFinalizedAlready();
        delete p.chunks;
        p.size = 0;
        emit PieceCleared(collection, pieceId);
    }

    /// @notice Repairs the content hash, title and description of a piece that is not yet finalized.
    function redescribePiece(
        uint256 collection,
        uint256 pieceId,
        bytes32 contentHash,
        string calldata title,
        string calldata description
    ) external onlyHouse {
        if (isSealed[collection]) revert CollectionSealedAlready();
        Piece storage p = _piece(collection, pieceId);
        if (p.finalized) revert PieceFinalizedAlready();
        p.contentHash = contentHash;
        p.title = title;
        p.description = description;
        emit PieceRedescribed(collection, pieceId, contentHash, title);
    }

    /// @notice Removes the last registered piece of an unsealed collection if it is not finalized, so a piece
    ///         registered by mistake does not block the seal forever. pieceCount shrinks by one.
    function dropLastPiece(uint256 collection) external onlyHouse {
        if (isSealed[collection]) revert CollectionSealedAlready();
        uint256 pieceId = pieceCount[collection];
        if (pieceId == 0) revert NoPieces();
        Piece storage p = _pieces[collection][pieceId];
        if (p.finalized) revert PieceFinalizedAlready();
        delete _pieces[collection][pieceId];
        pieceCount[collection] = pieceId - 1;
        emit PieceDropped(collection, pieceId);
    }

    function finalizePiece(uint256 collection, uint256 pieceId) external onlyHouse {
        Piece storage p = _piece(collection, pieceId);
        if (p.finalized) revert PieceFinalizedAlready();
        if (p.size == 0) revert EmptyPiece();
        bytes32 actual = keccak256(_read(p));
        if (actual != p.contentHash) revert ContentHashMismatch(p.contentHash, actual);
        p.finalized = true;
        emit PieceFinalized(collection, pieceId);
    }

    function seal(uint256 collection) external onlyHouse {
        if (isSealed[collection]) revert CollectionSealedAlready();
        uint256 count = pieceCount[collection];
        if (count == 0) revert NoPieces();
        for (uint256 i = 1; i <= count; ++i) {
            if (!_pieces[collection][i].finalized) revert PieceNotFinalized(i);
        }
        isSealed[collection] = true;
        emit CollectionSealed(collection);
    }

    // ---------------------------------------------------------------- reads

    function pieceBytes(uint256 collection, uint256 pieceId) external view returns (bytes memory) {
        return _read(_piece(collection, pieceId));
    }

    function pieceInfo(uint256 collection, uint256 pieceId)
        external
        view
        returns (
            bytes32 contentHash,
            string memory title,
            string memory description,
            uint256 size,
            uint256 chunkCount,
            bool finalized
        )
    {
        Piece storage p = _piece(collection, pieceId);
        return (p.contentHash, p.title, p.description, p.size, p.chunks.length, p.finalized);
    }

    function chunkPointer(uint256 collection, uint256 pieceId, uint256 index) external view returns (address) {
        return _piece(collection, pieceId).chunks[index];
    }

    function _piece(uint256 collection, uint256 pieceId) internal view returns (Piece storage p) {
        if (pieceId == 0 || pieceId > pieceCount[collection]) revert UnknownPiece();
        p = _pieces[collection][pieceId];
    }

    /// @dev Allocates the whole piece once and copies every chunk at its offset, so the cost is linear in the
    ///      piece size whatever the chunking.
    function _read(Piece storage p) internal view returns (bytes memory data) {
        data = new bytes(p.size);
        uint256 n = p.chunks.length;
        uint256 offset;
        for (uint256 i; i < n; ++i) {
            offset += SSTORE2.readInto(p.chunks[i], data, offset);
        }
        if (offset != data.length) revert SizeMismatch();
    }
}
