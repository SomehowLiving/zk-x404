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
