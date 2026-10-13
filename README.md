# Proof House · ARTIFACTS

Contracts for Proof House, a curator-run house for fully on-chain art, and its first collection ARTIFACTS:
256 encrypted generative pieces (255 editions and THE SOURCE). The art rules, protocol and reference renderer
live at <https://github.com/mylesdaughtry/proof-house> (`artifacts/RULES.md`, `artifacts/PROTOCOL.md`,
`artifacts/reference/`).

No fungible token or pool is created. The only tokens are ERC-721 NFTs, minted only when a piece is bought.
IMD (an existing ERC-20) is accepted as payment for the house's plain SVG collections.

## Contracts (launch order, 7 of the 8 allowed)

| # | Contract | Constructor | Role |
|---|----------|-------------|------|
| 0 | `ArtStorage` | `($owner)` | SSTORE2 chunk storage for plain SVG pieces; writes only from ArtHouse after the owner's one-time `setHouse`. |
| 1 | `ArtHouse` | `($owner, $contract:ArtStorage, 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A)` | The ledger: artists, brokers, sale modules, per-collection splits, per-currency balances, withdrawals, plain SVG collections (EIP-1167 clones of the `ArtCollection` implementation the constructor deploys), submissions. |
| 2 | `ArtifactsPiece` | `()` | Locked EIP-1167 implementation of a one-token ERC-721 + ERC-2981 piece. |
| 3 | `ArtifactsFactory` | `($owner, $contract:ArtHouse, $contract:ArtifactsPiece)` | ARTIFACTS registry: traits, ciphertext, commitments, lock, assignments, viewing keys, wrapped keys, claims (clone deployment), seal `tokenURI`. |
| 4 | `ArtifactsSale` | `($owner, $contract:ArtHouse, $contract:ArtifactsFactory)` | Edition sale at one ETH price through the ledger, with Chainlink VRF v2.5 assignment. |
| 5 | `ArtifactsAuction` | `($owner, $contract:ArtHouse, $contract:ArtifactsFactory)` | Single-lot ETH auction for THE SOURCE (piece 256). |
| 6 | `ArtifactsEscrow` | `($contract:ArtHouse, $contract:ArtifactsFactory)` | Keyed resale escrow. No owner: it has no administrative powers. |

The brief named four contracts; ArtifactsFactory was split into factory + sale + auction + escrow to stay well
under the EIP-170 size limit (every runtime is below 13 KB) and to keep each flow reviewable. Constructors
take only static values, `$owner` and earlier contracts, and call no other contract. No proxies, no
`DELEGATECALL` in any launch contract (the EIP-1167 clones delegate to the implementations, as the brief
requires, but the launch contracts themselves never do), no `SELFDESTRUCT`, no upgradeability.

The owner of every owned contract is the curator (`$owner`). Ownership is two-step (`transferOwnership`
then `acceptOwnership`); `renounceOwnership` reverts.

## Token facts

- ARTIFACTS: name `ARTIFACTS`, symbol `ARTIFACTS`. Each piece contract is named `ARTIFACTS #NNN`
  (three digits); piece 256 is `ARTIFACTS · THE SOURCE`. Token id = piece id. Exactly one token per
  piece contract, 256 pieces, fixed forever by `ArtifactsFactory.lock()` and the 255/1 caps in code.
- Later Proof House collections take their name and symbol from the curator at `createCollection`;
  their supply (`maxSupply`) is the number of registered pieces.
- Every piece pays an ERC-2981 royalty of 7.5% (750 bps) to its artist's current payout address in
  ArtHouse.

## ArtHouse ledger

- `approveArtist(artist, name, payout)` / `revokeArtist`; an artist changes its own payout with `setPayout`.
- `approveBroker` / `revokeBroker`.
- `createModuleCollection(artist)` creates a ledger-only collection (used for ARTIFACTS);
  `approveModule(module, collection)` lets a module call `recordSale{value}` and `recordResale{value}`.
- Split per collection in basis points, default broker 1500 / house 1500 / artist 7000, changed with
  `setSplit` (must sum to 10 000). The house keeps rounding. A broker earns only if approved and not the
  buyer; otherwise its share goes to the house.
- Balances are per account and currency (`address(0)` = ETH, the IMD address = IMD). `withdraw(currency)`
  pays the caller; `withdrawHouse(currency)` pays the house balance to the current owner. ETH is sent by
  `call`; a receiver that rejects ETH only blocks its own balance.
- Resales through the escrow pay the 7.5% royalty to the artist and credit the rest to the seller.
- Mints, purchases, sales records and withdrawals are `nonReentrant`; every credit is written before any
  token or ETH moves.

### Plain SVG collections

`createCollection(artist, name, symbol)` clones `ArtCollection`. Pieces go to ArtStorage through ArtHouse:
`registerPiece(collection, pieceId, contentHash, title, description)` (pieceId must be the next number;
curator or the collection's artist), `uploadChunk(collection, pieceId, index, data)` (index must be the next
chunk; curator or artist), `clearPiece` (curator, until finalized), `finalizePiece` (checks keccak256 of the
stored bytes against `contentHash`), `seal(collection)` (every piece finalized). Pieces over 100 KB are
rejected. `setPrices(collection, priceEth, priceImd)` only while the sale is closed; `openSale` needs a sealed
collection and a price. `mint(collection, pieceId, broker)` takes exactly the ETH price;
`mintWithIMD(collection, pieceId, broker, price)` reverts unless `price` equals the current IMD price and
then pulls exactly that (fee-on-transfer amounts are rejected). `tokenURI` is on-chain base64 JSON whose
image is the stored SVG.

Submissions: anyone calls `submit(contentHash, previewURI)`; the curator `acceptSubmission` /
`rejectSubmission` once.

## ARTIFACTS

1. **Upload and lock.** The curator calls `ArtifactsFactory.setPiece(pieceId, traits, ciphertext,
   commitment)` for pieces 1..256 (traits: title, palette, colour count, direction; ciphertext: the
   AES-256-GCM encrypted seed, stored with SSTORE2; commitment: keccak256 of the content key), then
   `lock()`. Nothing can change afterwards.
2. **Edition sale** (`ArtifactsSale`). Starts closed. `setPrice` (above zero, only while closed),
   `openSale` (needs the price, the VRF configuration and the locked factory), `closeSale`. `buy(broker)`
   pays exactly the price through `ArtHouse.recordSale` and requests one VRF v2.5 word; the callback
   assigns a random unassigned edition with a Fisher-Yates pool, so no edition is assigned twice or skipped.
   Purchases are capped at 255. If a callback never arrives, the curator may `retryRequest(purchaseId)`
   after 24 hours; the old request becomes stale and is ignored if it arrives later.
3. **Claim.** The buyer `registerViewingKey(x25519PublicKey)` on the factory; the curator
   `postContentKey(pieceId, wrappedKey)`; the buyer `claim(pieceId)` deploys the piece's own contract (an
   EIP-1167 clone of ArtifactsPiece) holding the ciphertext pointer, traits, commitment and the wrapped key.
4. **Seal.** `tokenURI` on every piece (and `ArtifactsFactory.tokenURI(pieceId)` before the claim) is
   on-chain JSON whose image is the seal: the framed window of RULES.md R8 exactly as in
   `reference/framed/`, with the piece's public traits and no dots. The status bar shows
   `PALETTE · kC · DIRECTION` and `SEED NNN`, where NNN is the piece number. THE SOURCE shows the
   MASTER frame.
5. **Resale** (`ArtifactsEscrow`). The owner `list(pieceId, price)`; the buyer `buy(pieceId, viewingKey)`
   pays exactly the price and the piece moves into escrow; the seller `postKey(pieceId, rewrappedKey)`;
   the buyer `confirm` releases payment, or anyone `release` 72 hours after the key was posted; the buyer
   may `cancel` until the key is posted (refund by pull with `withdrawRefund`). The escrow is an operator on
   every piece so it can move a listed piece without a separate approval; it only ever moves a piece from
   its listed seller. Plain ERC-721 transfers stay allowed: a transfer clears the wrapped key and records
   the previous owner, who may `setWrappedKey` for the new owner (the current owner may too).
6. **THE SOURCE** (`ArtifactsAuction`). The curator `configure(reserve, endTime)` (re-runnable while no bid
   exists). `bid()` must meet the reserve and beat the high bid by at least 5%; a bid in the final
   10 minutes moves the end to 10 minutes after it; outbid bids are refunded by pull. After the end anyone
   `settle()`: proceeds go through `ArtHouse.recordSale` (no broker, so the broker share goes to the
   house) and THE SOURCE is assigned to the winner, who claims it like an edition.

## After launch (owner actions, in order)

1. `ArtStorage.setHouse(ArtHouse)` — one time.
2. `ArtHouse.approveArtist(artist, "name", payout)` for the ARTIFACTS artist, then
   `ArtHouse.createModuleCollection(artist)` → collection id, then `ArtHouse.approveModule(x, id)` for
   each of ArtifactsFactory, ArtifactsSale, ArtifactsAuction and ArtifactsEscrow.
3. `ArtifactsFactory.setModules(ArtifactsSale, ArtifactsAuction, ArtifactsEscrow)` — one time.
4. `ArtifactsSale.configureVRF(coordinator, keyHash, subscriptionId, nativePayment)` — one time. Values
   come from the owner's Chainlink VRF v2.5 subscription at <https://vrf.chain.link> (create the
   subscription, fund it, add ArtifactsSale as a consumer; the coordinator and key hash are listed in
   Chainlink's docs for the launch chain). `nativePayment` false pays in LINK, true in ETH. Until it is set,
   `openSale` and `buy` revert with `VRFNotConfigured`.
5. `ArtifactsFactory.setPiece(...)` × 256 and `lock()`.
6. `ArtifactsSale.setPrice(price)` and `openSale()`; `ArtifactsAuction.configure(reserve, endTime)`.
7. During the sale: `ArtifactsFactory.postContentKey` for each assigned buyer who registered a viewing key.

Untested outside the mocks: the live IMD token at `0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A` is taken
from the brief and only used through `IERC20` on first use; the Chainlink coordinator is only used when set.

## Assumptions and choices

- The brief's auction paragraph is truncated after "proce"; proceeds are assumed to go through the ledger
  with the collection's split, like every other ARTIFACTS sale.
- Resale proceeds through the escrow honour the 7.5% royalty on-chain; the remainder is credited to the
  seller in the ledger (pull).
- The ARTIFACTS artist, its payout address and the ledger collection are set by the curator after launch
  (step 2); the brief names none.
- Chosen constants: VRF callback gas 250 000, 3 confirmations, retry delay 1 day; auction increment 500 bps
  and extension 10 minutes; escrow release delay 72 hours; piece size limit 100 KB.
- `SEED NNN` in an edition's seal is the piece number (the seed itself is secret).
- R9's on-chain render of THE SOURCE and the write-once `revealed` flag described in PROTOCOL.md are not in
  the brief given for this task and are not implemented; THE SOURCE serves its MASTER seal.
- Trait strings are curator-supplied and are not JSON-escaped; the curator must not use quotes or
  backslashes in them.

## Trust assumptions

The curator can approve or revoke artists, brokers and modules, set splits and prices, open and close sales,
clear unfinalized pieces, upload and lock ARTIFACTS data, post wrapped keys, retry VRF requests and
withdraw the house balance. The curator holds every content key until the last claim (PROTOCOL.md). A
dishonest seller can post a wrapped key that does not open; the contract cannot verify it. None of the
owner powers can mint without payment, move a buyer's token, or take another party's ledger balance.

## Development

```
forge build
FOUNDRY_FUZZ_SEED=0x7a5ed218cbaa5a65b36e22fe1de092bbc129872dbfdd7dbc2801e3f13802baed forge test
forge fmt --check
```

Dependencies are vendored as plain files under `lib/` (forge-std v1.9.6, OpenZeppelin Contracts v5.1.0).
`script/Deploy.s.sol` documents the constructor wiring; its `deploy` function is exercised by the tests. The
launch itself is performed by the IMD factory from the built bytecode. Tests pass with mocks for IMD and
the VRF coordinator; they are not a security audit, and an independent adversarial review is required
before mainnet.
