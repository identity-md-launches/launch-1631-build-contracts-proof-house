// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ArtifactsSeal, Traits} from "./libraries/ArtifactsSeal.sol";
import {SSTORE2} from "./libraries/SSTORE2.sol";
import {IArtifactsFactory} from "./interfaces/IArtifactsFactory.sol";

/// @title ArtifactsPiece
/// @notice A one-token ERC-721 with ERC-2981 for a single ARTIFACTS piece. Deployed once as a locked EIP-1167
///         implementation; the buyer's claim on ArtifactsFactory clones and initializes it. It holds the piece's
///         ciphertext pointer, public traits, content-key commitment and the wrapped key of the current owner.
contract ArtifactsPiece is ERC721, IERC2981 {
    uint256 public constant ROYALTY_BPS = 750;

    address public factory;
    uint16 public pieceId;
    address public ciphertext;
    bytes32 public commitment;
    Traits internal _traits;
    /// @notice Content key wrapped to the viewing key of `keyHolder`; empty after a transfer until re-wrapped.
    bytes public wrappedKey;
    address public keyHolder;
    /// @notice The owner before the last transfer; it may post the re-wrapped key for the new owner.
    address public previousOwner;
    bool internal _initialized;

    event WrappedKeySet(address indexed holder, address indexed by);

    error AlreadyInitialized();
    error NotKeyPoster();
    error EmptyKey();

    /// @dev Locks the implementation itself.
    constructor() ERC721("", "") {
        _initialized = true;
    }

    /// @notice Called once by ArtifactsFactory on the clone, inside the buyer's claim.
    function initialize(uint16 pieceId_, address owner_, bytes calldata wrappedKey_) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        factory = msg.sender;
        pieceId = pieceId_;
        (Traits memory t, address ciphertext_, bytes32 commitment_) = IArtifactsFactory(msg.sender).pieceInfo(pieceId_);
        _traits = t;
        ciphertext = ciphertext_;
        commitment = commitment_;
        wrappedKey = wrappedKey_;
        keyHolder = owner_;
        _mint(owner_, pieceId_);
    }

    // ---------------------------------------------------------------- keys

    /// @notice Posts the content key wrapped to the current owner's viewing key. Allowed for the current owner,
    ///         the previous owner (after a plain transfer), the factory and the factory's escrow.
    function setWrappedKey(bytes calldata wrapped) external {
        address owner_ = ownerOf(pieceId);
        if (
            msg.sender != owner_ && msg.sender != previousOwner && msg.sender != factory
                && msg.sender != IArtifactsFactory(factory).escrow()
        ) revert NotKeyPoster();
        if (wrapped.length == 0) revert EmptyKey();
        wrappedKey = wrapped;
        keyHolder = owner_;
        emit WrappedKeySet(owner_, msg.sender);
    }

    /// @dev Any transfer to a new holder clears the wrapped key and remembers who may re-wrap.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != keyHolder) {
            delete wrappedKey;
            previousOwner = from;
            keyHolder = to;
        }
    }

    /// @dev The factory's escrow may move the piece into and out of a keyed resale.
    function isApprovedForAll(address owner_, address operator) public view override returns (bool) {
        if (operator != address(0) && operator == IArtifactsFactory(factory).escrow()) return true;
        return super.isApprovedForAll(owner_, operator);
    }

    // ---------------------------------------------------------------- views

    function name() public view override returns (string memory) {
        return ArtifactsSeal.tokenName(pieceId);
    }

    function symbol() public pure override returns (string memory) {
        return "ARTIFACTS";
    }

    function traits() external view returns (Traits memory) {
        return _traits;
    }

    /// @notice The AES-256-GCM ciphertext of the seed, read from its SSTORE2 pointer.
    function ciphertextBytes() external view returns (bytes memory) {
        return SSTORE2.read(ciphertext);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return ArtifactsSeal.tokenURI(pieceId, _traits);
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        receiver = IArtifactsFactory(factory).royaltyReceiver();
        royaltyAmount = salePrice * ROYALTY_BPS / 10_000;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
