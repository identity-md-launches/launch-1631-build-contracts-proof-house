// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HouseOwnable} from "./HouseOwnable.sol";
import {IArtHouseLedger, IArtifactsFactory} from "./interfaces/IArtifactsFactory.sol";

/// @title ArtifactsAuction
/// @notice Single-lot ETH auction for THE SOURCE (piece 256). The curator sets the reserve and end time; each bid
///         must beat the high bid by at least 5%; a bid in the final 10 minutes moves the end to 10 minutes after
///         it; outbid bids are refunded by pull; settlement pays the proceeds through the ArtHouse ledger and
///         assigns THE SOURCE to the winner, who then claims it on ArtifactsFactory.
contract ArtifactsAuction is HouseOwnable, ReentrancyGuard {
    uint256 public constant MIN_INCREMENT_BPS = 500;
    uint64 public constant EXTENSION = 10 minutes;

    IArtHouseLedger public immutable house;
    IArtifactsFactory public immutable factory;

    uint256 public reserve;
    uint64 public endTime;
    address public highBidder;
    uint256 public highBid;
    bool public settled;
    mapping(address => uint256) public refunds;
    /// @notice Winning bid kept here if the ledger had revoked this module at settlement; forwarded by anyone later.
    uint256 public heldProceeds;

    event Configured(uint256 reserve, uint64 endTime);
    event Bid(address indexed bidder, uint256 amount, uint64 endTime);
    event RefundWithdrawn(address indexed bidder, uint256 amount);
    event Settled(address indexed winner, uint256 amount);
    event ProceedsHeld(uint256 amount);
    event ProceedsForwarded(uint256 amount);

    error ZeroAddress();
    error AuctionStarted();
    error NotConfigured();
    error Ended();
    error NotEnded();
    error BelowReserve();
    error BelowIncrement(uint256 minimum);
    error AlreadySettled();
    error NoBids();
    error BadEndTime();
    error NoRefund();
    error EthTransferFailed();
    error FactoryNotLocked();
    error FactoryNotWired();
    error NothingHeld();

    constructor(address owner_, address house_, address factory_) HouseOwnable(owner_) {
        if (house_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        house = IArtHouseLedger(house_);
        factory = IArtifactsFactory(factory_);
    }

    /// @notice Sets (or, while no bid exists, resets) the reserve and end time. Needs the locked factory to name
    ///         this contract as its auction, so a winning bid can always be settled.
    function configure(uint256 reserve_, uint64 endTime_) external onlyOwner {
        if (highBidder != address(0) || settled) revert AuctionStarted();
        if (reserve_ == 0) revert BelowReserve();
        if (endTime_ <= block.timestamp) revert BadEndTime();
        if (!factory.locked()) revert FactoryNotLocked();
        if (factory.auction() != address(this)) revert FactoryNotWired();
        reserve = reserve_;
        endTime = endTime_;
        emit Configured(reserve_, endTime_);
    }

    /// @notice The smallest acceptable bid: the reserve, or the high bid plus 5% rounded up (never equal to it).
    function minimumBid() public view returns (uint256) {
        if (highBid == 0) return reserve;
        return highBid + (highBid * MIN_INCREMENT_BPS + 9_999) / 10_000;
    }

    function bid() external payable nonReentrant {
        if (endTime == 0) revert NotConfigured();
        if (block.timestamp >= endTime) revert Ended();
        if (msg.value < reserve) revert BelowReserve();
        uint256 minimum = minimumBid();
        if (msg.value < minimum) revert BelowIncrement(minimum);
        if (highBidder != address(0)) refunds[highBidder] += highBid;
        highBidder = msg.sender;
        highBid = msg.value;
        if (endTime - block.timestamp < EXTENSION) endTime = uint64(block.timestamp) + EXTENSION;
        emit Bid(msg.sender, msg.value, endTime);
    }

    function withdrawRefund() external nonReentrant {
        uint256 amount = refunds[msg.sender];
        if (amount == 0) revert NoRefund();
        refunds[msg.sender] = 0;
        emit RefundWithdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice Anyone may settle after the end: THE SOURCE goes to the winner and the proceeds through the ledger.
    ///         If the curator revoked this module, the proceeds are held for forwardProceeds instead, so the
    ///         winner's assignment is never blocked.
    function settle() external nonReentrant {
        if (endTime == 0) revert NotConfigured();
        if (block.timestamp < endTime) revert NotEnded();
        if (settled) revert AlreadySettled();
        if (highBidder == address(0)) revert NoBids();
        settled = true;
        emit Settled(highBidder, highBid);
        bool ledgerOpen = house.isModule(address(this));
        if (!ledgerOpen) {
            heldProceeds = highBid;
            emit ProceedsHeld(highBid);
        }
        factory.assignSource(highBidder);
        if (ledgerOpen) house.recordSale{value: highBid}(highBidder, address(0));
    }

    /// @notice Forwards held proceeds through the ledger once this module is approved again.
    function forwardProceeds() external nonReentrant {
        uint256 amount = heldProceeds;
        if (amount == 0) revert NothingHeld();
        heldProceeds = 0;
        emit ProceedsForwarded(amount);
        house.recordSale{value: amount}(highBidder, address(0));
    }
}
