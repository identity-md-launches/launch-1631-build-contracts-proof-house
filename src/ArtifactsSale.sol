// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HouseOwnable} from "./HouseOwnable.sol";
import {IArtHouseLedger, IArtifactsFactory} from "./interfaces/IArtifactsFactory.sol";

/// @dev Chainlink VRF v2.5 coordinator surface used here (VRFV2PlusClient.RandomWordsRequest).
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}

/// @title ArtifactsSale
/// @notice Sells the 255 ARTIFACTS editions at one ETH price through the ArtHouse ledger, with brokers. Every
///         purchase requests Chainlink VRF v2.5 and the callback assigns a random edition that is not yet assigned,
///         so no edition is assigned twice or skipped.
contract ArtifactsSale is HouseOwnable, ReentrancyGuard {
    struct Purchase {
        address buyer;
        uint16 edition; // 0 until the VRF callback assigns one
        uint64 requestedAt;
        uint256 requestId;
    }

    uint16 public constant EDITION_COUNT = 255;
    uint32 public constant CALLBACK_GAS_LIMIT = 250_000;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    /// @notice After this long without a callback the curator may request fresh randomness for a purchase.
    uint64 public constant RETRY_DELAY = 1 days;
    bytes4 internal constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    IArtHouseLedger public immutable house;
    IArtifactsFactory public immutable factory;

    // Chainlink VRF v2.5, set once by the owner after deployment.
    address public vrfCoordinator;
    bytes32 public keyHash;
    uint256 public subscriptionId;
    bool public nativePayment;

    uint256 public price;
    bool public open;
    uint16 public purchaseCount;
    uint16 public assignedCount;
    mapping(uint256 purchaseId => Purchase) internal _purchases;
    mapping(uint256 requestId => uint256 purchaseId) public purchaseOfRequest;
    /// @dev Fisher-Yates pool over editions 1..255: slot i (0-based) holds edition i+1 until swapped.
    mapping(uint16 => uint16) internal _slots;

    event VRFConfigured(address coordinator, bytes32 keyHash, uint256 subscriptionId, bool nativePayment);
    event PriceSet(uint256 price);
    event SaleOpened();
    event SaleClosed();
    event Purchased(uint256 indexed purchaseId, address indexed buyer, address indexed broker, uint256 requestId);
    event RandomnessRequested(uint256 indexed purchaseId, uint256 requestId);
    event EditionAssigned(uint256 indexed purchaseId, uint16 indexed edition, address indexed buyer);

    error ZeroAddress();
    error VRFAlreadyConfigured();
    error VRFNotConfigured();
    error NotCoordinator();
    error SaleIsOpen();
    error SaleNotOpen();
    error NoPrice();
    error WrongPayment();
    error SoldOut();
    error FactoryNotLocked();
    error UnknownPurchase();
    error AlreadyAssigned();
    error TooEarly();

    constructor(address owner_, address house_, address factory_) HouseOwnable(owner_) {
        if (house_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        house = IArtHouseLedger(house_);
        factory = IArtifactsFactory(factory_);
    }

    // ---------------------------------------------------------------- configuration

    /// @notice One-time: the Chainlink VRF v2.5 coordinator, key hash and subscription this sale draws from.
    function configureVRF(address coordinator, bytes32 keyHash_, uint256 subscriptionId_, bool nativePayment_)
        external
        onlyOwner
    {
        if (vrfCoordinator != address(0)) revert VRFAlreadyConfigured();
        if (coordinator == address(0) || keyHash_ == bytes32(0) || subscriptionId_ == 0) revert ZeroAddress();
        vrfCoordinator = coordinator;
        keyHash = keyHash_;
        subscriptionId = subscriptionId_;
        nativePayment = nativePayment_;
        emit VRFConfigured(coordinator, keyHash_, subscriptionId_, nativePayment_);
    }

    /// @notice Sets the edition price; only while the sale is closed, and never zero.
    function setPrice(uint256 price_) external onlyOwner {
        if (open) revert SaleIsOpen();
        if (price_ == 0) revert NoPrice();
        price = price_;
        emit PriceSet(price_);
    }

    function openSale() external onlyOwner {
        if (price == 0) revert NoPrice();
        if (vrfCoordinator == address(0)) revert VRFNotConfigured();
        if (!factory.locked()) revert FactoryNotLocked();
        open = true;
        emit SaleOpened();
    }

    function closeSale() external onlyOwner {
        open = false;
        emit SaleClosed();
    }

    // ---------------------------------------------------------------- purchase

    /// @notice Buys one edition for exactly `price`. The edition is assigned by the VRF callback.
    function buy(address broker) external payable nonReentrant returns (uint256 purchaseId) {
        if (!open) revert SaleNotOpen();
        if (msg.value != price) revert WrongPayment();
        if (purchaseCount >= EDITION_COUNT) revert SoldOut();
        purchaseId = ++purchaseCount;
        Purchase storage p = _purchases[purchaseId];
        p.buyer = msg.sender;
        p.requestedAt = uint64(block.timestamp);
        house.recordSale{value: msg.value}(msg.sender, broker);
        uint256 requestId = _requestRandomness(purchaseId);
        emit Purchased(purchaseId, msg.sender, broker, requestId);
    }

    /// @notice Chainlink VRF v2.5 callback. Stale or unknown requests are ignored rather than reverted.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != vrfCoordinator) revert NotCoordinator();
        uint256 purchaseId = purchaseOfRequest[requestId];
        if (purchaseId == 0 || randomWords.length == 0) return;
        Purchase storage p = _purchases[purchaseId];
        if (p.edition != 0 || p.requestId != requestId) return;
        uint16 remaining = EDITION_COUNT - assignedCount;
        uint16 idx = uint16(randomWords[0] % remaining);
        uint16 edition = _slotValue(idx);
        _slots[idx] = _slotValue(remaining - 1);
        assignedCount += 1;
        p.edition = edition;
        emit EditionAssigned(purchaseId, edition, p.buyer);
        factory.assignEdition(edition, p.buyer);
    }

    /// @notice If a callback never arrived (for example an unfunded subscription at request time), the curator
    ///         may request fresh randomness for the purchase after RETRY_DELAY. The old request becomes stale.
    function retryRequest(uint256 purchaseId) external onlyOwner {
        Purchase storage p = _purchases[purchaseId];
        if (p.buyer == address(0)) revert UnknownPurchase();
        if (p.edition != 0) revert AlreadyAssigned();
        if (block.timestamp < p.requestedAt + RETRY_DELAY) revert TooEarly();
        p.requestedAt = uint64(block.timestamp);
        _requestRandomness(purchaseId);
    }

    function purchase(uint256 purchaseId) external view returns (Purchase memory) {
        return _purchases[purchaseId];
    }

    function _requestRandomness(uint256 purchaseId) internal returns (uint256 requestId) {
        address coordinator = vrfCoordinator;
        if (coordinator == address(0)) revert VRFNotConfigured();
        requestId = IVRFCoordinatorV2Plus(coordinator)
            .requestRandomWords(
                IVRFCoordinatorV2Plus.RandomWordsRequest({
                    keyHash: keyHash,
                    subId: subscriptionId,
                    requestConfirmations: REQUEST_CONFIRMATIONS,
                    callbackGasLimit: CALLBACK_GAS_LIMIT,
                    numWords: 1,
                    extraArgs: abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, nativePayment)
                })
            );
        _purchases[purchaseId].requestId = requestId;
        purchaseOfRequest[requestId] = purchaseId;
        emit RandomnessRequested(purchaseId, requestId);
    }

    function _slotValue(uint16 idx) internal view returns (uint16) {
        uint16 v = _slots[idx];
        return v == 0 ? idx + 1 : v;
    }
}
