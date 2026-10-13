// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HouseOwnable} from "./HouseOwnable.sol";
import {ArtStorage} from "./ArtStorage.sol";
import {ArtCollection} from "./ArtCollection.sol";

/// @title ArtHouse
/// @notice The Proof House ledger. The curator (owner) approves artists, brokers and sale modules; every sale is
///         split per collection in basis points between broker, house and artist; balances are kept per currency
///         (ETH = address(0), IMD) and every party withdraws its own. ArtHouse also runs the plain SVG collections:
///         pieces are uploaded to ArtStorage, each collection is an EIP-1167 clone of ArtCollection, and mints go
///         through this ledger in ETH or IMD.
contract ArtHouse is HouseOwnable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Artist {
        string name;
        address payout;
        bool approved;
    }

    struct Collection {
        address token; // ArtCollection clone; zero for module collections such as ARTIFACTS
        address artist;
        uint16 brokerBps;
        uint16 houseBps;
        uint16 artistBps;
        uint128 priceEth;
        uint128 priceImd;
        bool open;
    }

    enum SubmissionStatus {
        Pending,
        Accepted,
        Rejected
    }

    struct Submission {
        address submitter;
        bytes32 contentHash;
        string previewURI;
        SubmissionStatus status;
    }

    uint16 public constant BPS = 10_000;
    uint16 public constant ROYALTY_BPS = 750;
    uint16 public constant DEFAULT_BROKER_BPS = 1500;
    uint16 public constant DEFAULT_HOUSE_BPS = 1500;
    uint16 public constant DEFAULT_ARTIST_BPS = 7000;
    address public constant ETH = address(0);

    ArtStorage public immutable artStorage;
    IERC20 public immutable imd;
    address public immutable collectionImplementation;

    mapping(address => Artist) internal _artists;
    mapping(address => bool) public isBroker;
    /// @notice The collection a module is, or was last, approved for. Kept after revocation for royalty lookups.
    mapping(address module => uint256 collection) public moduleCollection;
    /// @notice Whether a module may currently record sales.
    mapping(address module => bool) public isModule;
    uint256 public collectionCount;
    mapping(uint256 => Collection) internal _collections;
    /// @notice account => currency => withdrawable amount. The house's own balance sits under address(this).
    mapping(address => mapping(address => uint256)) public balances;
    uint256 public submissionCount;
    mapping(uint256 => Submission) internal _submissions;

    event ArtistApproved(address indexed artist, string name, address payout);
    event ArtistRevoked(address indexed artist);
    event ArtistPayoutChanged(address indexed artist, address payout);
    event BrokerApproved(address indexed broker);
    event BrokerRevoked(address indexed broker);
    event ModuleApproved(address indexed module, uint256 indexed collection);
    event ModuleRevoked(address indexed module);
    event CollectionCreated(
        uint256 indexed collection, address indexed artist, address token, string name, string symbol
    );
    event SplitSet(uint256 indexed collection, uint16 brokerBps, uint16 houseBps, uint16 artistBps);
    event PricesSet(uint256 indexed collection, uint256 priceEth, uint256 priceImd);
    event SaleOpened(uint256 indexed collection);
    event SaleClosed(uint256 indexed collection);
    event Sale(
        uint256 indexed collection,
        address indexed buyer,
        address indexed broker,
        address currency,
        uint256 amount,
        uint256 brokerShare,
        uint256 houseShare,
        uint256 artistShare
    );
    event Resale(uint256 indexed collection, address indexed seller, address currency, uint256 amount, uint256 royalty);
    event Credited(address indexed account, address indexed currency, uint256 amount);
    event Withdrawn(address indexed account, address indexed currency, uint256 amount);
    event Submitted(uint256 indexed id, address indexed submitter, bytes32 contentHash, string previewURI);
    event SubmissionDecided(uint256 indexed id, SubmissionStatus status);

    error ZeroAddress();
    error NotApprovedArtist();
    error NotModule();
    error UnknownCollection();
    error NotSvgCollection();
    error NotCuratorOrArtist();
    error BadSplit();
    error SaleNotOpen();
    error SaleOpen();
    error NotSealed();
    error NoPrice();
    error WrongPayment();
    error WrongPrice();
    error PieceNotFinalized();
    error NothingToWithdraw();
    error EthTransferFailed();
    error TransferAmountMismatch();
    error UnknownSubmission();
    error SubmissionDecidedAlready();
    error EmptyName();

    constructor(address owner_, address storage_, address imd_) HouseOwnable(owner_) {
        if (storage_ == address(0) || imd_ == address(0)) revert ZeroAddress();
        artStorage = ArtStorage(storage_);
        imd = IERC20(imd_);
        collectionImplementation = address(new ArtCollection());
    }

    // ---------------------------------------------------------------- roles

    /// @notice Approves an artist, or renames one already approved. The payout address belongs to the artist:
    ///         re-approving an approved artist keeps the payout it chose and ignores `payout`.
    function approveArtist(address artist_, string calldata name, address payout) external onlyOwner {
        if (artist_ == address(0) || payout == address(0)) revert ZeroAddress();
        if (bytes(name).length == 0) revert EmptyName();
        Artist storage a = _artists[artist_];
        if (a.approved) payout = a.payout;
        a.name = name;
        a.payout = payout;
        a.approved = true;
        emit ArtistApproved(artist_, name, payout);
    }

    function revokeArtist(address artist_) external onlyOwner {
        _artists[artist_].approved = false;
        emit ArtistRevoked(artist_);
    }

    /// @notice An artist moves its own payout address. Credits already written stay with the old address.
    function setPayout(address payout) external {
        if (!_artists[msg.sender].approved) revert NotApprovedArtist();
        if (payout == address(0)) revert ZeroAddress();
        _artists[msg.sender].payout = payout;
        emit ArtistPayoutChanged(msg.sender, payout);
    }

    function artist(address account) external view returns (Artist memory) {
        return _artists[account];
    }

    function approveBroker(address broker) external onlyOwner {
        if (broker == address(0)) revert ZeroAddress();
        isBroker[broker] = true;
        emit BrokerApproved(broker);
    }

    function revokeBroker(address broker) external onlyOwner {
        isBroker[broker] = false;
        emit BrokerRevoked(broker);
    }

    /// @notice Approves a sale module (for example ArtifactsSale) to record ETH sales for `collection`.
    function approveModule(address module, uint256 collection_) external onlyOwner {
        if (module == address(0)) revert ZeroAddress();
        _requireCollection(collection_);
        moduleCollection[module] = collection_;
        isModule[module] = true;
        emit ModuleApproved(module, collection_);
    }

    /// @notice Stops a module from recording sales. The collection it was approved for stays on record so royalty
    ///         lookups through the module keep resolving.
    function revokeModule(address module) external onlyOwner {
        isModule[module] = false;
        emit ModuleRevoked(module);
    }

    // ---------------------------------------------------------------- collections

    /// @notice Creates a plain SVG collection as an ArtCollection clone with the name and symbol the curator gives.
    function createCollection(address artist_, string calldata name, string calldata symbol)
        external
        onlyOwner
        returns (uint256 id, address token)
    {
        if (!_artists[artist_].approved) revert NotApprovedArtist();
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyName();
        id = ++collectionCount;
        token = Clones.clone(collectionImplementation);
        _initCollection(id, artist_, token);
        ArtCollection(token).initialize(address(this), address(artStorage), id, name, symbol);
        emit CollectionCreated(id, artist_, token, name, symbol);
    }

    /// @notice Creates a ledger-only collection whose tokens live in an external module (ARTIFACTS).
    function createModuleCollection(address artist_) external onlyOwner returns (uint256 id) {
        if (!_artists[artist_].approved) revert NotApprovedArtist();
        id = ++collectionCount;
        _initCollection(id, artist_, address(0));
        emit CollectionCreated(id, artist_, address(0), "", "");
    }

    function _initCollection(uint256 id, address artist_, address token) internal {
        Collection storage c = _collections[id];
        c.token = token;
        c.artist = artist_;
        c.brokerBps = DEFAULT_BROKER_BPS;
        c.houseBps = DEFAULT_HOUSE_BPS;
        c.artistBps = DEFAULT_ARTIST_BPS;
    }

    /// @notice Sets a collection's split. For a plain SVG collection only while its sale is closed, like setPrices.
    ///         A module collection's sale state lives in its module, so its split is a curator power at any time.
    function setSplit(uint256 collection_, uint16 brokerBps, uint16 houseBps, uint16 artistBps) external onlyOwner {
        Collection storage c = _requireCollection(collection_);
        if (c.open) revert SaleOpen();
        if (uint256(brokerBps) + houseBps + artistBps != BPS) revert BadSplit();
        c.brokerBps = brokerBps;
        c.houseBps = houseBps;
        c.artistBps = artistBps;
        emit SplitSet(collection_, brokerBps, houseBps, artistBps);
    }

    function collection(uint256 id) external view returns (Collection memory) {
        return _collections[id];
    }

    /// @notice Where ERC-2981 royalties of `collection` go: its artist's current payout address.
    function royaltyReceiver(uint256 collection_) public view returns (address) {
        return _artists[_requireCollection(collection_).artist].payout;
    }

    /// @notice Royalty receiver for the collection a module is approved for.
    function moduleRoyaltyReceiver(address module) external view returns (address) {
        uint256 id = moduleCollection[module];
        if (id == 0) revert NotModule();
        return royaltyReceiver(id);
    }

    // ---------------------------------------------------------------- SVG pieces (ArtStorage pass-through)

    function registerPiece(
        uint256 collection_,
        uint256 pieceId,
        bytes32 contentHash,
        string calldata title,
        string calldata description
    ) external {
        _requireCuratorOrArtist(collection_);
        artStorage.registerPiece(collection_, pieceId, contentHash, title, description);
    }

    function uploadChunk(uint256 collection_, uint256 pieceId, uint256 index, bytes calldata data) external {
        _requireCuratorOrArtist(collection_);
        artStorage.uploadChunk(collection_, pieceId, index, data);
    }

    function clearPiece(uint256 collection_, uint256 pieceId) external onlyOwner {
        _requireSvgCollection(collection_);
        artStorage.clearPiece(collection_, pieceId);
    }

    /// @notice Curator repair of an unfinalized piece's content hash, title and description.
    function redescribePiece(
        uint256 collection_,
        uint256 pieceId,
        bytes32 contentHash,
        string calldata title,
        string calldata description
    ) external onlyOwner {
        _requireSvgCollection(collection_);
        artStorage.redescribePiece(collection_, pieceId, contentHash, title, description);
    }

    /// @notice Curator removal of the last registered piece while it is not finalized and the collection is unsealed.
    function dropLastPiece(uint256 collection_) external onlyOwner {
        _requireSvgCollection(collection_);
        artStorage.dropLastPiece(collection_);
    }

    function finalizePiece(uint256 collection_, uint256 pieceId) external {
        _requireCuratorOrArtist(collection_);
        artStorage.finalizePiece(collection_, pieceId);
    }

    function seal(uint256 collection_) external onlyOwner {
        _requireSvgCollection(collection_);
        artStorage.seal(collection_);
    }

    // ---------------------------------------------------------------- SVG sales

    function setPrices(uint256 collection_, uint128 priceEth, uint128 priceImd) external onlyOwner {
        Collection storage c = _requireSvgCollection(collection_);
        if (c.open) revert SaleOpen();
        c.priceEth = priceEth;
        c.priceImd = priceImd;
        emit PricesSet(collection_, priceEth, priceImd);
    }

    function openSale(uint256 collection_) external onlyOwner {
        Collection storage c = _requireSvgCollection(collection_);
        if (!artStorage.isSealed(collection_)) revert NotSealed();
        if (c.priceEth == 0 && c.priceImd == 0) revert NoPrice();
        c.open = true;
        emit SaleOpened(collection_);
    }

    function closeSale(uint256 collection_) external onlyOwner {
        _requireSvgCollection(collection_).open = false;
        emit SaleClosed(collection_);
    }

    /// @notice Buys `pieceId` of a plain SVG collection for exactly its ETH price.
    function mint(uint256 collection_, uint256 pieceId, address broker) external payable nonReentrant {
        Collection storage c = _requireSvgCollection(collection_);
        if (!c.open) revert SaleNotOpen();
        if (c.priceEth == 0) revert NoPrice();
        if (msg.value != c.priceEth) revert WrongPayment();
        _requireFinalized(collection_, pieceId);
        _split(collection_, c, msg.sender, broker, ETH, msg.value);
        ArtCollection(c.token).mint(msg.sender, pieceId);
    }

    /// @notice Buys `pieceId` with IMD. `price` must equal the current IMD price; exactly that amount is pulled.
    function mintWithIMD(uint256 collection_, uint256 pieceId, address broker, uint256 price) external nonReentrant {
        Collection storage c = _requireSvgCollection(collection_);
        if (!c.open) revert SaleNotOpen();
        if (c.priceImd == 0) revert NoPrice();
        if (price != c.priceImd) revert WrongPrice();
        _requireFinalized(collection_, pieceId);
        _split(collection_, c, msg.sender, broker, address(imd), price);
        uint256 before = imd.balanceOf(address(this));
        imd.safeTransferFrom(msg.sender, address(this), price);
        if (imd.balanceOf(address(this)) - before != price) revert TransferAmountMismatch();
        ArtCollection(c.token).mint(msg.sender, pieceId);
    }

    // ---------------------------------------------------------------- module sales

    /// @notice An approved module records an ETH sale it collected; the value is split like any house sale.
    function recordSale(address buyer, address broker) external payable nonReentrant {
        uint256 id = _requireModule(msg.sender);
        if (msg.value == 0) revert WrongPayment();
        _split(id, _collections[id], buyer, broker, ETH, msg.value);
    }

    /// @notice An approved module records an ETH resale: the artist royalty is kept, the rest is credited to the seller.
    function recordResale(address seller) external payable nonReentrant {
        uint256 id = _requireModule(msg.sender);
        if (msg.value == 0 || seller == address(0)) revert WrongPayment();
        uint256 royalty = msg.value * ROYALTY_BPS / BPS;
        _credit(_artists[_collections[id].artist].payout, ETH, royalty);
        _credit(seller, ETH, msg.value - royalty);
        emit Resale(id, seller, ETH, msg.value, royalty);
    }

    // ---------------------------------------------------------------- withdrawals

    function withdraw(address currency) external nonReentrant {
        _payOut(msg.sender, msg.sender, currency);
    }

    /// @notice The house balance is paid to the current owner.
    function withdrawHouse(address currency) external onlyOwner nonReentrant {
        _payOut(address(this), msg.sender, currency);
    }

    function _payOut(address account, address to, address currency) internal {
        uint256 amount = balances[account][currency];
        if (amount == 0) revert NothingToWithdraw();
        balances[account][currency] = 0;
        emit Withdrawn(account, currency, amount);
        if (currency == ETH) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }

    // ---------------------------------------------------------------- submissions

    function submit(bytes32 contentHash, string calldata previewURI) external returns (uint256 id) {
        id = ++submissionCount;
        _submissions[id] = Submission(msg.sender, contentHash, previewURI, SubmissionStatus.Pending);
        emit Submitted(id, msg.sender, contentHash, previewURI);
    }

    function acceptSubmission(uint256 id) external onlyOwner {
        _decide(id, SubmissionStatus.Accepted);
    }

    function rejectSubmission(uint256 id) external onlyOwner {
        _decide(id, SubmissionStatus.Rejected);
    }

    function submission(uint256 id) external view returns (Submission memory) {
        return _submissions[id];
    }

    function _decide(uint256 id, SubmissionStatus status) internal {
        if (id == 0 || id > submissionCount) revert UnknownSubmission();
        Submission storage s = _submissions[id];
        if (s.status != SubmissionStatus.Pending) revert SubmissionDecidedAlready();
        s.status = status;
        emit SubmissionDecided(id, status);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Writes every credit of a sale. A broker earns only if approved and not the buyer; otherwise its share
    ///      goes to the house, which also keeps any rounding.
    function _split(uint256 id, Collection storage c, address buyer, address broker, address currency, uint256 amount)
        internal
    {
        uint256 brokerShare = amount * c.brokerBps / BPS;
        uint256 artistShare = amount * c.artistBps / BPS;
        uint256 houseShare = amount - brokerShare - artistShare;
        bool brokerEarns = broker != address(0) && broker != buyer && isBroker[broker];
        if (brokerEarns) {
            _credit(broker, currency, brokerShare);
        } else {
            houseShare += brokerShare;
            brokerShare = 0;
        }
        _credit(_artists[c.artist].payout, currency, artistShare);
        _credit(address(this), currency, houseShare);
        emit Sale(id, buyer, brokerEarns ? broker : address(0), currency, amount, brokerShare, houseShare, artistShare);
    }

    function _credit(address account, address currency, uint256 amount) internal {
        if (amount == 0) return;
        balances[account][currency] += amount;
        emit Credited(account, currency, amount);
    }

    function _requireModule(address module) internal view returns (uint256 id) {
        if (!isModule[module]) revert NotModule();
        id = moduleCollection[module];
    }

    function _requireCollection(uint256 id) internal view returns (Collection storage c) {
        if (id == 0 || id > collectionCount) revert UnknownCollection();
        c = _collections[id];
    }

    function _requireSvgCollection(uint256 id) internal view returns (Collection storage c) {
        c = _requireCollection(id);
        if (c.token == address(0)) revert NotSvgCollection();
    }

    /// @dev The curator always; the collection's artist only while still approved.
    function _requireCuratorOrArtist(uint256 id) internal view {
        Collection storage c = _requireSvgCollection(id);
        if (msg.sender == owner()) return;
        if (msg.sender != c.artist) revert NotCuratorOrArtist();
        if (!_artists[c.artist].approved) revert NotApprovedArtist();
    }

    function _requireFinalized(uint256 id, uint256 pieceId) internal view {
        (,,,,, bool finalized) = artStorage.pieceInfo(id, pieceId);
        if (!finalized) revert PieceNotFinalized();
    }
}
