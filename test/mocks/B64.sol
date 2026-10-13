// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal base64 decoder for tests (standard alphabet, '=' padding).
library B64 {
    function decode(string memory input) internal pure returns (bytes memory out) {
        bytes memory data = bytes(input);
        require(data.length % 4 == 0, "bad length");
        uint256 outLen = data.length / 4 * 3;
        if (data.length > 0 && data[data.length - 1] == "=") outLen--;
        if (data.length > 1 && data[data.length - 2] == "=") outLen--;
        out = new bytes(outLen);
        uint256 o;
        for (uint256 i; i < data.length; i += 4) {
            uint256 n = (_val(data[i]) << 18) | (_val(data[i + 1]) << 12) | (_val(data[i + 2]) << 6) | _val(data[i + 3]);
            if (o < outLen) out[o++] = bytes1(uint8(n >> 16));
            if (o < outLen) out[o++] = bytes1(uint8(n >> 8));
            if (o < outLen) out[o++] = bytes1(uint8(n));
        }
    }

    /// @dev Strips a `data:...;base64,` prefix and decodes the payload.
    function decodeDataURI(string memory uri, string memory prefix) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        bytes memory p = bytes(prefix);
        bytes memory payload = new bytes(b.length - p.length);
        for (uint256 i; i < p.length; ++i) {
            require(b[i] == p[i], "bad prefix");
        }
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = b[i + p.length];
        }
        return string(decode(string(payload)));
    }

    function _val(bytes1 c) private pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65;
        if (x >= 97 && x <= 122) return x - 97 + 26;
        if (x >= 48 && x <= 57) return x - 48 + 52;
        if (x == 43) return 62;
        if (x == 47) return 63;
        if (x == 61) return 0;
        revert("bad char");
    }
}
