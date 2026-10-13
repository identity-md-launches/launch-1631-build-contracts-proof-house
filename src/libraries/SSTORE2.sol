// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SSTORE2
/// @notice Stores bytes as the runtime code of a throwaway contract (prefixed with a STOP byte so it can never
///         be executed) and reads them back with EXTCODECOPY. Every function is internal so nothing is linked.
library SSTORE2 {
    /// @notice Largest payload one pointer can hold: the EIP-170 code size limit minus the leading STOP byte.
    uint256 internal constant MAX_DATA_BYTES = 24_576 - 1;

    error WriteFailed();
    error ReadOutOfBounds();
    error DataTooLarge();

    /// @dev Deploys `data` behind a leading 0x00 byte and returns the pointer.
    function write(bytes memory data) internal returns (address pointer) {
        // The runtime length is encoded in 16 bits and capped by EIP-170; anything larger would be truncated.
        if (data.length > MAX_DATA_BYTES) revert DataTooLarge();
        // init code: 0x61 <len16> 0x80 0x60 0x0a 0x3d 0x39 0x3d 0xf3 || 0x00 || data
        // PUSH2 len, DUP1, PUSH1 0x0a, RETURNDATASIZE, CODECOPY, RETURNDATASIZE, RETURN
        bytes memory code = abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
        assembly ("memory-safe") {
            pointer := create(0, add(code, 32), mload(code))
        }
        if (pointer == address(0)) revert WriteFailed();
    }

    /// @dev Reads the whole payload stored at `pointer`.
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 size = pointer.code.length;
        if (size == 0) revert ReadOutOfBounds();
        unchecked {
            size -= 1;
        }
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 32), 1, size)
        }
    }

    /// @dev Copies the payload stored at `pointer` into `dest` at `offset` and returns the payload size.
    ///      Reverts if the payload does not fit, so a caller that sized `dest` from its own bookkeeping cannot
    ///      overrun it.
    function readInto(address pointer, bytes memory dest, uint256 offset) internal view returns (uint256 size) {
        size = pointer.code.length;
        if (size == 0) revert ReadOutOfBounds();
        unchecked {
            size -= 1;
        }
        if (offset + size > dest.length) revert ReadOutOfBounds();
        assembly ("memory-safe") {
            extcodecopy(pointer, add(add(dest, 32), offset), 1, size)
        }
    }
}
