# Zero-Knowledge Proof Setup Guide

## Overview

Your privacy payment system needs **Zero-Knowledge (ZK) proofs** to allow users to prove they own a commitment in the Merkle tree without revealing which one. This guide will walk you through the complete setup.

---

## 🎯 What You're Building

A ZK circuit that proves:
- "I know a secret and nullifier that hash to a commitment"
- "This commitment exists in the Merkle tree"
- "Here's the Merkle proof to verify it"
- **WITHOUT revealing which commitment or the secret!**

---

## 📦 Required Tools

### 1. Install Node.js Dependencies

```bash
npm install --save-dev circomlib circomlibjs snarkjs

# Or with yarn
yarn add -D circomlib circomlibjs snarkjs
```

### 2. Install Circom Compiler

**Option A: Using npm (easiest)**
```bash
npm install -g circom
```

**Option B: From source (recommended for production)**
```bash
# Install Rust first
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Clone and build circom
git clone https://github.com/iden3/circom.git
cd circom
cargo build --release
cargo install --path circom

# Verify installation
circom --version
```

### 3. Install snarkjs CLI

```bash
npm install -g snarkjs
```

---

## 🔧 Project Structure

Create this folder structure:

```
zk-privacy/
├── circuits/
│   ├── withdraw.circom          # Main withdrawal circuit
│   ├── merkleTree.circom        # Merkle tree verification
│   └── commitment.circom        # Commitment generation
├── scripts/
│   ├── 1-compile-circuit.sh     # Compile circuits
│   ├── 2-generate-keys.sh       # Generate proving/verification keys
│   ├── 3-generate-proof.js      # Generate proofs (off-chain)
│   └── 4-deploy-verifier.js     # Deploy verifier contract
├── build/                        # Compiled circuits (gitignore)
├── keys/                         # Proving/verification keys (gitignore)
└── test/
    └── circuit.test.js
```

---

## 📝 Step 1: Write Circom Circuits

### A. Commitment Circuit (`circuits/commitment.circom`)

```circom
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
```

### B. Merkle Tree Circuit (`circuits/merkleTree.circom`)

```circom
pragma circom 2.0.0;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";

// Verify Merkle tree path
template MerkleTreeChecker(levels) {
    signal input leaf;
    signal input pathElements[levels];
    signal input pathIndices[levels];
    signal output root;

    component hashers[levels];
    component selectors[levels];

    signal levelHashes[levels + 1];
    levelHashes[0] <== leaf;

    for (var i = 0; i < levels; i++) {
        // Select left or right based on path index
        selectors[i] = Selector();
        selectors[i].in[0] <== levelHashes[i];
        selectors[i].in[1] <== pathElements[i];
        selectors[i].index <== pathIndices[i];

        // Hash the pair
        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== selectors[i].out[0];
        hashers[i].inputs[1] <== selectors[i].out[1];

        levelHashes[i + 1] <== hashers[i].out;
    }

    root <== levelHashes[levels];
}

// Select left or right element
template Selector() {
    signal input in[2];
    signal input index;
    signal output out[2];

    signal tmp;
    tmp <== (in[1] - in[0]) * index;
    out[0] <== in[0] + tmp;
    out[1] <== in[1] - tmp;
}
```

### C. Main Withdrawal Circuit (`circuits/withdraw.circom`)

```circom
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
```

---

## 🔨 Step 2: Compile Circuits

Create `scripts/1-compile-circuit.sh`:

```bash
#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔨 Compiling Circom circuits...${NC}\n"

# Create build directory
mkdir -p build
mkdir -p keys

# Compile the circuit
echo -e "${GREEN}📝 Compiling withdraw circuit...${NC}"
circom circuits/withdraw.circom \
    --r1cs --wasm --sym --c \
    -o build/

# Check if compilation succeeded
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Circuit compiled successfully!${NC}\n"
    
    # Print circuit info
    echo -e "${BLUE}📊 Circuit Information:${NC}"
    snarkjs r1cs info build/withdraw.r1cs
    
    echo -e "\n${GREEN}✅ Generated files:${NC}"
    echo "  - build/withdraw.r1cs (constraints)"
    echo "  - build/withdraw.wasm (witness generator)"
    echo "  - build/withdraw.sym (symbol table)"
else
    echo -e "${RED}❌ Compilation failed!${NC}"
    exit 1
fi
```

Make it executable and run:
```bash
chmod +x scripts/1-compile-circuit.sh
./scripts/1-compile-circuit.sh
```

---

## 🔑 Step 3: Generate Proving Keys

Create `scripts/2-generate-keys.sh`:

```bash
#!/bin/bash

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}🔑 Generating ZK proving keys...${NC}\n"

# This process takes 10-30 minutes for production circuits!
# For testing, we use a smaller circuit

# Step 1: Start a new powers of tau ceremony
echo -e "${GREEN}📝 Step 1: Powers of Tau ceremony...${NC}"
snarkjs powersoftau new bn128 14 keys/pot14_0000.ptau -v

# Step 2: Contribute to the ceremony
echo -e "${GREEN}📝 Step 2: Contributing to ceremony...${NC}"
snarkjs powersoftau contribute keys/pot14_0000.ptau keys/pot14_0001.ptau \
    --name="First contribution" -v -e="$(date +%s)"

# Step 3: Prepare phase 2
echo -e "${GREEN}📝 Step 3: Preparing phase 2...${NC}"
snarkjs powersoftau prepare phase2 keys/pot14_0001.ptau keys/pot14_final.ptau -v

# Step 4: Generate zkey (circuit-specific proving key)
echo -e "${GREEN}📝 Step 4: Generating circuit proving key...${NC}"
snarkjs groth16 setup build/withdraw.r1cs keys/pot14_final.ptau keys/withdraw_0000.zkey

# Step 5: Contribute to phase 2
echo -e "${GREEN}📝 Step 5: Phase 2 contribution...${NC}"
snarkjs zkey contribute keys/withdraw_0000.zkey keys/withdraw_final.zkey \
    --name="Circuit contribution" -v -e="$(date +%s)"

# Step 6: Export verification key
echo -e "${GREEN}📝 Step 6: Exporting verification key...${NC}"
snarkjs zkey export verificationkey keys/withdraw_final.zkey keys/verification_key.json

# Step 7: Generate Solidity verifier
echo -e "${GREEN}📝 Step 7: Generating Solidity verifier...${NC}"
snarkjs zkey export solidityverifier keys/withdraw_final.zkey contracts/Verifier.sol

echo -e "\n${GREEN}✅ Key generation complete!${NC}"
echo -e "${YELLOW}⚠️  IMPORTANT: In production, use a trusted setup ceremony!${NC}"
echo -e "${YELLOW}⚠️  Multiple parties should contribute to the Powers of Tau.${NC}"
```

Run it:
```bash
chmod +x scripts/2-generate-keys.sh
./scripts/2-generate-keys.sh
```

**⚠️ This takes 10-30 minutes!** Be patient.

---

## 🎯 Step 4: Generate Proofs (Off-Chain)

Create `scripts/3-generate-proof.js`:

```javascript
const snarkjs = require("snarkjs");
const { buildPoseidon } = require("circomlibjs");
const fs = require("fs");

async function generateProof(inputs) {
    console.log("🔐 Generating zero-knowledge proof...\n");

    // Load Poseidon hash function
    const poseidon = await buildPoseidon();

    // Generate witness
    console.log("📝 Generating witness...");
    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        inputs,
        "build/withdraw_js/withdraw.wasm",
        "keys/withdraw_final.zkey"
    );

    console.log("✅ Witness generated");
    console.log("✅ Proof generated\n");

    // Format proof for Solidity
    const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
    
    const argv = calldata
        .replace(/["[\]\s]/g, "")
        .split(",")
        .map(x => BigInt(x).toString());

    const formattedProof = {
        pA: [argv[0], argv[1]],
        pB: [
            [argv[2], argv[3]],
            [argv[4], argv[5]]
        ],
        pC: [argv[6], argv[7]],
        pubSignals: [argv[8]]
    };

    console.log("📋 Formatted proof for Solidity:");
    console.log(JSON.stringify(formattedProof, null, 2));

    return formattedProof;
}

// Example usage
async function example() {
    const { buildPoseidon } = require("circomlibjs");
    const poseidon = await buildPoseidon();

    // User's secret data
    const secret = BigInt("12345"); // Random secret
    const nullifier = BigInt("67890"); // Random nullifier

    // Generate commitment
    const commitment = poseidon([secret, nullifier]);
    const nullifierHash = poseidon([nullifier]);

    console.log("🔑 Generated commitment:", commitment.toString());
    console.log("🔑 Nullifier hash:", nullifierHash.toString());

    // Mock Merkle tree path (in reality, get from contract)
    const pathElements = new Array(20).fill(BigInt(0));
    const pathIndices = new Array(20).fill(0);

    const inputs = {
        // Private inputs
        secret: secret.toString(),
        nullifier: nullifier.toString(),
        pathElements: pathElements.map(x => x.toString()),
        pathIndices: pathIndices,

        // Public inputs
        root: "12345678901234567890", // From contract
        recipient: "1234567890123456789012345678901234567890", // Address as number
        relayer: "0",
        fee: "0",
        refund: "0"
    };

    const proof = await generateProof(inputs);
    
    // Save proof to file
    fs.writeFileSync(
        "proof.json",
        JSON.stringify({ proof, commitment: commitment.toString(), nullifierHash: nullifierHash.toString() }, null, 2)
    );
    
    console.log("\n✅ Proof saved to proof.json");
}

// Run example if called directly
if (require.main === module) {
    example().catch(console.error);
}

module.exports = { generateProof };
```

---

## 🚀 Step 5: Deploy Verifier Contract

The Solidity verifier was generated in Step 3. Now deploy it:

Create `scripts/4-deploy-verifier.js`:

```javascript
const hre = require("hardhat");

async function main() {
    console.log("📝 Deploying Verifier contract...\n");

    // The verifier was generated by snarkjs
    const Verifier = await hre.ethers.getContractFactory("Groth16Verifier");
    const verifier = await Verifier.deploy();
    await verifier.waitForDeployment();

    const address = await verifier.getAddress();
    console.log("✅ Verifier deployed at:", address);

    // Update your deployment script to use this instead of MockVerifier
    console.log("\n📋 Update your main deployment script:");
    console.log(`const verifierAddress = "${address}";`);
}

main().catch(console.error);
```

---

## 🧪 Step 6: Test the Circuit

Create `test/circuit.test.js`:

```javascript
const { expect } = require("chai");
const { buildPoseidon } = require("circomlibjs");
const snarkjs = require("snarkjs");
const path = require("path");

describe("Withdraw Circuit", function() {
    let poseidon;
    let circuit;

    before(async function() {
        this.timeout(60000);
        poseidon = await buildPoseidon();
        
        // Load circuit
        circuit = await wasm_tester(
            path.join(__dirname, "../circuits/withdraw.circom")
        );
    });

    it("Should generate valid proof for withdrawal", async function() {
        this.timeout(60000);

        const secret = BigInt(12345);
        const nullifier = BigInt(67890);

        // Generate commitment
        const commitment = poseidon([secret, nullifier]);
        const nullifierHash = poseidon([nullifier]);

        // Mock Merkle path
        const pathElements = new Array(20).fill(BigInt(0));
        const pathIndices = new Array(20).fill(0);

        const inputs = {
            secret: secret.toString(),
            nullifier: nullifier.toString(),
            pathElements: pathElements.map(x => x.toString()),
            pathIndices: pathIndices,
            root: commitment.toString(), // Simplified: commitment is root
            recipient: "123456789",
            relayer: "0",
            fee: "0",
            refund: "0"
        };

        // Generate witness
        const witness = await circuit.calculateWitness(inputs);
        await circuit.checkConstraints(witness);

        console.log("✅ Circuit constraints satisfied!");
    });
});

// Helper to load WASM tester
async function wasm_tester(circuitPath) {
    const circom_tester = require("circom_tester");
    return await circom_tester.wasm(circuitPath);
}
```

Run tests:
```bash
npx hardhat test test/circuit.test.js
```

---

## 📦 Step 7: Integration with Smart Contracts

Update your deployment script to use the real verifier:

```javascript
// In deploy.js, replace MockVerifier with:

console.log("📝 Deploying Groth16 Verifier...");
const Verifier = await ethers.getContractFactory("Groth16Verifier");
const verifier = await Verifier.deploy();
await verifier.waitForDeployment();
const verifierAddress = await verifier.getAddress();
console.log("✅ Verifier deployed at:", verifierAddress);
```

---

## 🔄 Complete Workflow

### For Users (Off-Chain):

1. **Deposit**:
   ```javascript
   const secret = randomBigInt();
   const nullifier = randomBigInt();
   const commitment = poseidon([secret, nullifier]);
   await privacyTree.deposit(commitment, amount);
   ```

2. **Get Merkle Proof**:
   ```javascript
   const { pathElements, pathIndices, root } = await getMerkleProof(commitment);
   ```

3. **Generate ZK Proof**:
   ```javascript
   const proof = await generateProof({
       secret,
       nullifier,
       pathElements,
       pathIndices,
       root,
       recipient,
       relayer: 0,
       fee: 0,
       refund: 0
   });
   ```

4. **Withdraw**:
   ```javascript
   await privacyTree.withdraw(
       proof.pA,
       proof.pB,
       proof.pC,
       proof.pubSignals,
       nullifierHash,
       recipientAddress,
       amount,
       chainId
   );
   ```

---

## 📚 Additional Scripts Needed

Create `scripts/helpers/merkle-tree.js`:

```javascript
const { buildPoseidon } = require("circomlibjs");

class MerkleTree {
    constructor(levels) {
        this.levels = levels;
        this.tree = {};
        this.leaves = [];
        this.zeroValue = BigInt("21663839004416932945382355908790599225266501822907911457504978515578255421292");
    }

    async init() {
        this.poseidon = await buildPoseidon();
        this.zeros = [this.zeroValue];
        
        for (let i = 1; i < this.levels; i++) {
            this.zeros.push(this.hash(this.zeros[i-1], this.zeros[i-1]));
        }
    }

    hash(left, right) {
        return this.poseidon([left, right]);
    }

    insert(leaf) {
        const index = this.leaves.length;
        this.leaves.push(leaf);
        this.tree[`0-${index}`] = leaf;
        this._updatePath(index);
        return index;
    }

    _updatePath(index) {
        let currentIndex = index;
        let currentHash = this.leaves[index];

        for (let level = 0; level < this.levels; level++) {
            const isLeft = currentIndex % 2 === 0;
            const siblingIndex = isLeft ? currentIndex + 1 : currentIndex - 1;
            
            const siblingHash = this.tree[`${level}-${siblingIndex}`] || this.zeros[level];
            
            currentHash = isLeft 
                ? this.hash(currentHash, siblingHash)
                : this.hash(siblingHash, currentHash);
            
            currentIndex = Math.floor(currentIndex / 2);
            this.tree[`${level + 1}-${currentIndex}`] = currentHash;
        }
    }

    getProof(index) {
        const pathElements = [];
        const pathIndices = [];
        
        let currentIndex = index;
        
        for (let level = 0; level < this.levels; level++) {
            const isLeft = currentIndex % 2 === 0;
            const siblingIndex = isLeft ? currentIndex + 1 : currentIndex - 1;
            
            pathElements.push(
                this.tree[`${level}-${siblingIndex}`] || this.zeros[level]
            );
            pathIndices.push(isLeft ? 0 : 1);
            
            currentIndex = Math.floor(currentIndex / 2);
        }
        
        return { pathElements, pathIndices, root: this.root() };
    }

    root() {
        return this.tree[`${this.levels}-0`] || this.zeros[this.levels];
    }
}

module.exports = { MerkleTree };
```

---

## ⚡ Quick Start Commands

```bash
# 1. Install dependencies
npm install circomlib circomlibjs snarkjs circom_tester
npm install -g circom snarkjs

# 2. Compile circuits
./scripts/1-compile-circuit.sh

# 3. Generate keys (takes 10-30 min)
./scripts/2-generate-keys.sh

# 4. Test circuit
npx hardhat test test/circuit.test.js

# 5. Generate example proof
node scripts/3-generate-proof.js

# 6. Deploy verifier
npx hardhat run scripts/4-deploy-verifier.js --network localhost
```

---

## 🎓 Learning Resources

- **Circom Documentation**: https://docs.circom.io/
- **snarkjs Guide**: https://github.com/iden3/snarkjs
- **ZK Whiteboard Sessions**: https://zkhack.dev/whiteboard/
- **Circomlib Circuits**: https://github.com/iden3/circomlib
- **Tornado Cash Circuits** (reference): https://github.com/tornadocash/tornado-core

---

## ⚠️ Production Checklist

Before mainnet deployment:

- [ ] Use trusted setup ceremony (multi-party computation)
- [ ] Audit circuits by ZK experts
- [ ] Test with various input combinations
- [ ] Implement proper key management
- [ ] Set up decentralized proof generation
- [ ] Add circuit version control
- [ ] Monitor for vulnerabilities
- [ ] Plan for circuit upgrades

---

## 🆘 Troubleshooting

**Issue**: "circom: command not found"
```bash
# Solution: Install circom globally
npm install -g circom
```

**Issue**: "Out of memory during key generation"
```bash
# Solution: Increase Node.js memory
export NODE_OPTIONS="--max-old-space-size=8192"
./scripts/2-generate-keys.sh
```

**Issue**: "Proof verification fails"
```bash
# Solution: Check input formatting
# Ensure all inputs are strings
# Verify Merkle path is correct
# Check nullifier hasn't been used
```

---

This setup will give you a complete, working ZK proof system for your privacy payments! 🎉