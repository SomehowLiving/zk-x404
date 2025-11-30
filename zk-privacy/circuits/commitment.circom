pragma circom 2.0.0;

include "../node_modules/circomlib/circuits/poseidon.circom";

// Generate commitment from secret and nullifier
template Commitment() {
    signal input secret;
    signal input nullifier;
    signal output commitment;

    component hasher = Poseidon(2);
    hasher.inputs[0] <== secret;
    hasher.inputs[1] <== nullifier;
    
    commitment <== hasher.out;
}
