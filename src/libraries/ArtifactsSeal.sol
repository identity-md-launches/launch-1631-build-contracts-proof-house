// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice The public traits of an ARTIFACTS piece (RULES.md R3).
struct Traits {
    string title;
    string palette;
    uint8 colourCount;
    string direction;
}

/// @title ArtifactsSeal
/// @notice Draws the seal of an ARTIFACTS piece: the framed OS window of RULES.md R8 exactly as in the reference
///         framed pieces (1080 x 1080 sheet, window at 200,220 of 680 x 640, inset second border, Menlo 12.5 px),
///         with the piece's public traits and no dots. Everything is internal so nothing is linked.
library ArtifactsSeal {
    uint16 internal constant SOURCE_ID = 256;

    function tokenName(uint16 pieceId) internal pure returns (string memory) {
        if (pieceId == SOURCE_ID) return unicode"ARTIFACTS · THE SOURCE";
        return string.concat("ARTIFACTS #", pad3(pieceId));
    }

    function pad3(uint16 n) internal pure returns (string memory) {
        bytes memory b = new bytes(3);
        b[0] = bytes1(uint8(48 + (n / 100) % 10));
        b[1] = bytes1(uint8(48 + (n / 10) % 10));
        b[2] = bytes1(uint8(48 + n % 10));
        return string(b);
    }

    /// @notice The seal SVG.
    function svg(uint16 pieceId, Traits memory t) internal pure returns (string memory) {
        bool isSource = pieceId == SOURCE_ID;
        string memory menu = isSource ? "File View Reveal" : "File View Run";
        string memory title = isSource ? unicode"ARTIFACTS ◆ MASTER" : t.title;
        string memory statusLeft = isSource
            ? "THE SOURCE"
            : string.concat(t.palette, unicode" · ", Strings.toString(t.colourCount), unicode"C · ", t.direction);
        string memory statusRight = isSource ? unicode"FIDELITY · MAX · 1/1" : string.concat("SEED ", pad3(pieceId));
        string memory dividers = isSource
            ? string.concat(_line("263.0"), _line("266.0"), _line("814.0"), _line("817.0"))
            : string.concat(_line("266.0"), _line("814.0"));
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1080 1080" width="1080" height="1080">',
            '<rect width="1080" height="1080" fill="#ffffff"/>',
            '<g fill="#1a1a1a" font-family="Menlo, ui-monospace, monospace" dominant-baseline="middle" letter-spacing="0.5">',
            '<rect x="200" y="220" width="680" height="640" fill="none" stroke="#1a1a1a" stroke-width="1.3"/>',
            '<rect x="203.2" y="223.2" width="673.6" height="633.6" fill="none" stroke="#1a1a1a" stroke-width="1.3"/>',
            _text("218.0", "250.0", "start", menu),
            _text("862.0", "250.0", "end", title),
            dividers,
            _text("218.0", "833.0", "start", statusLeft),
            _text("862.0", "833.0", "end", statusRight),
            "</g></svg>"
        );
    }

    /// @notice Fully on-chain base64 JSON metadata whose image is the seal.
    function tokenURI(uint16 pieceId, Traits memory t) internal pure returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"',
            tokenName(pieceId),
            '","description":"Proof House \\u00b7 ARTIFACTS. One of 256 encrypted generative pieces; the seal shows the piece\'s public traits.",',
            '"attributes":[{"trait_type":"Title","value":"',
            t.title,
            '"},{"trait_type":"Palette","value":"',
            t.palette,
            '"},{"trait_type":"Colour Count","value":',
            Strings.toString(t.colourCount),
            '},{"trait_type":"Direction","value":"',
            t.direction,
            '"}],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg(pieceId, t))),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function _line(string memory y) private pure returns (string memory) {
        return
            string.concat('<line x1="203.2" y1="', y, '" x2="876.8" y2="', y, '" stroke="#1a1a1a" stroke-width="1.2"/>');
    }

    function _text(string memory x, string memory y, string memory anchor, string memory body)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '<text x="',
            x,
            '" y="',
            y,
            '" font-size="12.5" text-anchor="',
            anchor,
            '" xml:space="preserve">',
            body,
            "</text>"
        );
    }
}
