// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Storage min-heap of packed bid keys (escrow << 64 | ~bidId) used to keep the largest escrows.
/// @dev For equal escrow the newer bid has the smaller key, so older bids are kept on ties.
library BidHeap {
  function key(uint256 escrow, uint256 bidId) internal pure returns (uint256) {
    return (escrow << 64) | (type(uint64).max - bidId);
  }

  function bidIdOf(uint256 k) internal pure returns (uint256) {
    return type(uint64).max - uint64(k);
  }

  function escrowOf(uint256 k) internal pure returns (uint256) {
    return k >> 64;
  }

  function insert(uint256[] storage heap, uint256 k) internal {
    heap.push(k);
    uint256 i = heap.length - 1;
    while (i != 0) {
      uint256 parent = (i - 1) / 2;
      uint256 pk = heap[parent];
      if (pk <= k) break;
      heap[i] = pk;
      i = parent;
    }
    heap[i] = k;
  }

  function popMin(uint256[] storage heap) internal returns (uint256 minKey) {
    minKey = heap[0];
    uint256 last = heap[heap.length - 1];
    heap.pop();
    uint256 n = heap.length;
    if (n == 0) return minKey;
    uint256 i;
    while (true) {
      uint256 child = 2 * i + 1;
      if (child >= n) break;
      uint256 ck = heap[child];
      if (child + 1 < n) {
        uint256 rk = heap[child + 1];
        if (rk < ck) {
          child += 1;
          ck = rk;
        }
      }
      if (ck >= last) break;
      heap[i] = ck;
      i = child;
    }
    heap[i] = last;
  }
}
