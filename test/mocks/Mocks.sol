// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IVRFCoordinatorV2Plus, ArtifactsSale} from "../../src/ArtifactsSale.sol";

/// @dev Stands in for the existing IMD ERC-20 in local tests.
contract MockIMD is ERC20 {
    constructor() ERC20("IdentityMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fee-on-transfer token to prove mintWithIMD rejects anything but the exact amount.
contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xfee), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev Records VRF v2.5 requests; the test fulfils them explicitly. Demonstrates local behaviour only.
contract MockVRFCoordinator is IVRFCoordinatorV2Plus {
    uint256 public nextRequestId = 1;
    mapping(uint256 => address) public consumerOf;
    RandomWordsRequest public lastRequest;

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        consumerOf[requestId] = msg.sender;
        lastRequest = req;
    }

    function fulfill(uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        ArtifactsSale(consumerOf[requestId]).rawFulfillRandomWords(requestId, words);
    }
}

/// @dev Rejects ETH so withdrawals to it fail.
contract Rejector {
    receive() external payable {
        revert("no");
    }
}

/// @dev Tries to re-enter ArtHouse.withdraw during its own withdrawal.
contract Reenterer {
    address public target;
    bool public reentered;

    constructor(address target_) {
        target = target_;
    }

    receive() external payable {
        (bool ok,) = target.call(abi.encodeWithSignature("withdraw(address)", address(0)));
        reentered = ok;
    }
}
