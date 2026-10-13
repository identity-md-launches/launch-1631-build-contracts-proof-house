// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Traits} from "../libraries/ArtifactsSeal.sol";

interface IArtifactsFactory {
    function pieceInfo(uint16 pieceId)
        external
        view
        returns (Traits memory traits, address ciphertext, bytes32 commitment);
    function royaltyReceiver() external view returns (address);
    function escrow() external view returns (address);
    function locked() external view returns (bool);
    function pieceContract(uint16 pieceId) external view returns (address);
    function assignedTo(uint16 pieceId) external view returns (address);
    function assignEdition(uint16 pieceId, address to) external;
    function assignSource(address to) external;
    function registerViewingKeyFor(address account, bytes32 viewingPublicKey) external;
}

interface IArtifactsPiece {
    function initialize(uint16 pieceId, address owner_, bytes calldata wrappedKey_) external;
    function setWrappedKey(bytes calldata wrapped) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IArtHouseLedger {
    function recordSale(address buyer, address broker) external payable;
    function recordResale(address seller) external payable;
    function moduleRoyaltyReceiver(address module) external view returns (address);
}
