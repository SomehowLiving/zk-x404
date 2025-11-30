pragma circom 2.0.0;

include "./commitment.circom";
include "./merkleTree.circom";

// Main circuit for private withdrawal
template Withdraw(levels) {
    // Private inputs (not revealed)
    signal input secret;
    signal input nullifier;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    // Public inputs (revealed on-chain)
    signal input root;
    signal input recipient;
    signal input relayer;
    signal input fee;
    signal input refund;

    // Outputs
    signal output nullifierHash;

    // 1. Generate commitment from secret and nullifier
    component commitmentHasher = Commitment();
    commitmentHasher.secret <== secret;
    commitmentHasher.nullifier <== nullifier;

    // 2. Verify commitment is in Merkle tree
    component tree = MerkleTreeChecker(levels);
    tree.leaf <== commitmentHasher.commitment;
    for (var i = 0; i < levels; i++) {
        tree.pathElements[i] <== pathElements[i];
        tree.pathIndices[i] <== pathIndices[i];
    }

    // Verify root matches
    root === tree.root;

    // 3. Generate nullifier hash (prevents double-spending)
    component nullifierHasher = Poseidon(1);
    nullifierHasher.inputs[0] <== nullifier;
    nullifierHash <== nullifierHasher.out;

    // 4. Add dummy constraints to prevent tampering
    signal recipientSquare;
    signal relayerSquare;
    signal feeSquare;
    signal refundSquare;
    
    recipientSquare <== recipient * recipient;
    relayerSquare <== relayer * relayer;
    feeSquare <== fee * fee;
    refundSquare <== refund * refund;
}

component main {public [root, recipient, relayer, fee, refund]} = Withdraw(20);
