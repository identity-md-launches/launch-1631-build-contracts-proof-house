// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title JsonEscape
/// @notice Escapes a string for use inside a JSON string literal: quotes, backslashes and control characters.
///         Internal only, so nothing is linked.
library JsonEscape {
    bytes16 private constant HEX = "0123456789abcdef";

    function escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c == 0x22 || c == 0x5c) extra += 1;
            else if (c < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        uint256 o;
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            uint8 c = uint8(ch);
            if (c == 0x22 || c == 0x5c) {
                out[o++] = "\\";
                out[o++] = ch;
            } else if (c < 0x20) {
                out[o++] = "\\";
                out[o++] = "u";
                out[o++] = "0";
                out[o++] = "0";
                out[o++] = HEX[c >> 4];
                out[o++] = HEX[c & 0x0f];
            } else {
                out[o++] = ch;
            }
        }
        return string(out);
    }
}
