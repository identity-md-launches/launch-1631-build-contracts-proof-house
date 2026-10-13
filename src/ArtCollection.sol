// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ArtStorage} from "./ArtStorage.sol";

interface IArtHouseRoyalty {
    function royaltyReceiver(uint256 collection) external view returns (address);
}

/// @title ArtCollection
/// @notice ERC-721 + ERC-2981 implementation for a plain SVG collection of Proof House. ArtHouse deploys this
///         implementation from its constructor and clones it (EIP-1167) for every later collection. Token ids are
///         piece ids; metadata and the SVG are read from ArtStorage and served as on-chain base64 JSON.
contract ArtCollection is ERC721, IERC2981 {
    uint256 public constant ROYALTY_BPS = 750;

    address public house;
    ArtStorage public artStorage;
    uint256 public collectionId;
    string internal _collectionName;
    string internal _collectionSymbol;
    bool internal _initialized;

    error AlreadyInitialized();
    error NotHouse();

    /// @dev The implementation itself is locked so it can never be initialized or minted on.
    constructor() ERC721("", "") {
        _initialized = true;
    }

    function initialize(
        address house_,
        address storage_,
        uint256 collectionId_,
        string calldata name_,
        string calldata symbol_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        house = house_;
        artStorage = ArtStorage(storage_);
        collectionId = collectionId_;
        _collectionName = name_;
        _collectionSymbol = symbol_;
    }

    /// @notice Only ArtHouse mints, and only inside a paid purchase.
    function mint(address to, uint256 pieceId) external {
        if (msg.sender != house) revert NotHouse();
        _safeMint(to, pieceId);
    }

    function name() public view override returns (string memory) {
        return _collectionName;
    }

    function symbol() public view override returns (string memory) {
        return _collectionSymbol;
    }

    /// @notice Supply is the number of registered pieces; exactly one token can exist per piece.
    function maxSupply() external view returns (uint256) {
        return artStorage.pieceCount(collectionId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        (, string memory title, string memory description,,,) = artStorage.pieceInfo(collectionId, tokenId);
        bytes memory svg = artStorage.pieceBytes(collectionId, tokenId);
        bytes memory json = abi.encodePacked(
            '{"name":"',
            title,
            '","description":"',
            description,
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(svg),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        receiver = IArtHouseRoyalty(house).royaltyReceiver(collectionId);
        royaltyAmount = salePrice * ROYALTY_BPS / 10_000;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
