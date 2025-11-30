// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MerkleCommitmentRegistry
 * @notice Stores payment commitments in a Merkle tree for privacy
 * @dev Core privacy primitive - proves payment without revealing identity
 */
contract MerkleCommitmentRegistry {
    // Merkle tree parameters
    uint256 public constant TREE_DEPTH = 20;
    uint256 public constant MAX_LEAVES = 2**TREE_DEPTH;
    
    // Current state
    uint256 public nextLeafIndex;
    bytes32 public currentRoot;
    
    // Storage
    mapping(uint256 => bytes32) public leaves;
    mapping(bytes32 => bool) public usedNullifiers;
    mapping(bytes32 => bool) public knownRoots;
    
    // Root history (for async proof verification)
    bytes32[] public rootHistory;
    uint256 public constant ROOT_HISTORY_SIZE = 30;
    
    // Events
    event CommitmentAdded(uint256 indexed leafIndex, bytes32 commitment, bytes32 newRoot);
    event NullifierUsed(bytes32 indexed nullifier);
    
    // Errors
    error TreeFull();
    error NullifierAlreadyUsed();
    error InvalidRoot();
    
    constructor() {
        // Initialize with empty tree root
        currentRoot = bytes32(0);
        knownRoots[currentRoot] = true;
        rootHistory.push(currentRoot);
    }
    
    /**
     * @notice Add a payment commitment to the tree
     * @param commitment Hash of (amount, recipient, secret)
     * @return leafIndex The index where commitment was inserted
     */
    function addCommitment(bytes32 commitment) external returns (uint256) {
        if (nextLeafIndex >= MAX_LEAVES) revert TreeFull();
        
        uint256 leafIndex = nextLeafIndex;
        leaves[leafIndex] = commitment;
        
        // Update Merkle root (simplified - use incremental merkle tree in production)
        bytes32 newRoot = _updateRoot(leafIndex, commitment);
        currentRoot = newRoot;
        knownRoots[newRoot] = true;
        
        // Update root history
        _updateRootHistory(newRoot);
        
        nextLeafIndex++;
        
        emit CommitmentAdded(leafIndex, commitment, newRoot);
        return leafIndex;
    }
    
    /**
     * @notice Mark a nullifier as used (prevents double-spending)
     * @param nullifier Unique hash derived from commitment secret
     */
    function useNullifier(bytes32 nullifier) external {
        if (usedNullifiers[nullifier]) revert NullifierAlreadyUsed();
        usedNullifiers[nullifier] = true;
        emit NullifierUsed(nullifier);
    }
    
    /**
     * @notice Check if a root is valid (current or recent)
     * @param root The Merkle root to verify
     */
    function isKnownRoot(bytes32 root) public view returns (bool) {
        return knownRoots[root];
    }
    
    /**
     * @notice Check if nullifier has been used
     */
    function isNullifierUsed(bytes32 nullifier) public view returns (bool) {
        return usedNullifiers[nullifier];
    }
    
    /**
     * @dev Update Merkle root after adding leaf (simplified)
     * In production, use incremental Merkle tree library
     */
    function _updateRoot(uint256 leafIndex, bytes32 leaf) internal view returns (bytes32) {
        bytes32 computedHash = leaf;
        uint256 index = leafIndex;
        
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            bytes32 sibling;
            
            if (index % 2 == 0) {
                // Right sibling
                sibling = leaves[index + 1];
                if (sibling == bytes32(0)) sibling = _zeroHash(i);
                computedHash = _hashPair(computedHash, sibling);
            } else {
                // Left sibling
                sibling = leaves[index - 1];
                computedHash = _hashPair(sibling, computedHash);
            }
            
            index = index / 2;
        }
        
        return computedHash;
    }
    
    /**
     * @dev Maintain circular buffer of recent roots
     */
    function _updateRootHistory(bytes32 newRoot) internal {
        if (rootHistory.length >= ROOT_HISTORY_SIZE) {
            // Remove oldest root from known roots
            bytes32 oldestRoot = rootHistory[0];
            delete knownRoots[oldestRoot];
            
            // Shift array (gas intensive - optimize in production)
            for (uint256 i = 0; i < rootHistory.length - 1; i++) {
                rootHistory[i] = rootHistory[i + 1];
            }
            rootHistory[rootHistory.length - 1] = newRoot;
        } else {
            rootHistory.push(newRoot);
        }
    }
    
    /**
     * @dev Hash a pair of nodes (mimics Poseidon hash in circuit)
     */
    function _hashPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }
    
    /**
     * @dev Get zero hash for empty subtree at depth
     */
    function _zeroHash(uint256 depth) internal pure returns (bytes32) {
        // Precomputed zero hashes for empty subtrees
        // In production, compute these off-chain
        return keccak256(abi.encodePacked("ZERO", depth));
    }
    
    /**
     * @notice Get current tree state
     */
    function getTreeState() external view returns (
        bytes32 root,
        uint256 leafCount,
        uint256 capacity
    ) {
        return (currentRoot, nextLeafIndex, MAX_LEAVES);
    }
}