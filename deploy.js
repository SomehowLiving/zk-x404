const hre = require("hardhat");
const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 Starting Privacy Payment System Deployment...\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("📍 Deploying contracts with account:", deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // ============================================
  // CONFIGURATION - UPDATE THESE VALUES
  // ============================================
  
  const config = {
    // ERC-4337 EntryPoint (official deployment on most chains)
    entryPoint: "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789", // v0.6
    
    // USDC token address (update per chain)
    usdc: {
      ethereum: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      polygon: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174",
      arbitrum: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
      optimism: "0x7F5c764cBc14f9669B88837ca1490cCa17c31607",
      // Add your chain's USDC address here
      local: "0x0000000000000000000000000000000000000000" // Deploy mock for testing
    },
    
    // LayerZero Endpoint (update per chain)
    layerZero: {
      ethereum: "0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675",
      polygon: "0x3c2269811836af69497E5F486A85D7316753cf62",
      arbitrum: "0x3c2269811836af69497E5F486A85D7316753cf62",
      optimism: "0x3c2269811836af69497E5F486A85D7316753cf62",
      // Add your chain's LayerZero endpoint
      local: "0x0000000000000000000000000000000000000000" // Mock for testing
    },
    
    // Fee recipient for privacy tree fees
    feeRecipient: deployer.address, // Change to treasury address in production
    
    // Initial paymaster settings
    usdcToEthRate: ethers.parseEther("2500"), // 1 ETH = 2500 USDC
    maxGasPrice: ethers.parseUnits("100", "gwei"),
    maxGasLimit: 1000000,
  };

  // Get current chain ID
  const chainId = (await ethers.provider.getNetwork()).chainId;
  console.log("🌐 Deploying on chain ID:", chainId.toString(), "\n");

  // Select addresses based on chain
  let usdcAddress = config.usdc.local;
  let lzEndpoint = config.layerZero.local;

  if (chainId === 1n) { // Ethereum
    usdcAddress = config.usdc.ethereum;
    lzEndpoint = config.layerZero.ethereum;
  } else if (chainId === 137n) { // Polygon
    usdcAddress = config.usdc.polygon;
    lzEndpoint = config.layerZero.polygon;
  } else if (chainId === 42161n) { // Arbitrum
    usdcAddress = config.usdc.arbitrum;
    lzEndpoint = config.layerZero.arbitrum;
  } else if (chainId === 10n) { // Optimism
    usdcAddress = config.usdc.optimism;
    lzEndpoint = config.layerZero.optimism;
  }

  // ============================================
  // STEP 0: Deploy Mock Contracts (if needed)
  // ============================================
  
  if (usdcAddress === "0x0000000000000000000000000000000000000000") {
    console.log("⚠️  No USDC address configured for this chain");
    console.log("📝 Deploying Mock USDC for testing...");
    
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const mockUsdc = await MockERC20.deploy("Mock USDC", "USDC", 6);
    await mockUsdc.waitForDeployment();
    usdcAddress = await mockUsdc.getAddress();
    console.log("✅ Mock USDC deployed at:", usdcAddress);
    
    // Mint some tokens for testing
    await mockUsdc.mint(deployer.address, ethers.parseUnits("1000000", 6));
    console.log("💵 Minted 1,000,000 USDC to deployer\n");
  }

  if (lzEndpoint === "0x0000000000000000000000000000000000000000") {
    console.log("⚠️  No LayerZero endpoint configured for this chain");
    console.log("📝 Deploying Mock LayerZero Endpoint...");
    
    const MockLZEndpoint = await ethers.getContractFactory("MockLZEndpoint");
    const mockLz = await MockLZEndpoint.deploy();
    await mockLz.waitForDeployment();
    lzEndpoint = await mockLz.getAddress();
    console.log("✅ Mock LayerZero deployed at:", lzEndpoint, "\n");
  }

  // ============================================
  // STEP 1: Deploy Mock Verifier (ZK Proof)
  // ============================================
  
  console.log("📝 Step 1: Deploying Mock Verifier...");
  const MockVerifier = await ethers.getContractFactory("MockVerifier");
  const verifier = await MockVerifier.deploy();
  await verifier.waitForDeployment();
  const verifierAddress = await verifier.getAddress();
  console.log("✅ Verifier deployed at:", verifierAddress, "\n");

  // ============================================
  // STEP 2: Deploy PrivacyMerkleTree
  // ============================================
  
  console.log("📝 Step 2: Deploying PrivacyMerkleTree...");
  const PrivacyMerkleTree = await ethers.getContractFactory("PrivacyMerkleTree");
  const privacyTree = await PrivacyMerkleTree.deploy(
    usdcAddress,
    verifierAddress,
    config.feeRecipient
  );
  await privacyTree.waitForDeployment();
  const privacyTreeAddress = await privacyTree.getAddress();
  console.log("✅ PrivacyMerkleTree deployed at:", privacyTreeAddress, "\n");

  // ============================================
  // STEP 3: Deploy PrivacyPaymaster
  // ============================================
  
  console.log("📝 Step 3: Deploying PrivacyPaymaster...");
  const PrivacyPaymaster = await ethers.getContractFactory("PrivacyPaymaster");
  const paymaster = await PrivacyPaymaster.deploy(
    config.entryPoint,
    usdcAddress
  );
  await paymaster.waitForDeployment();
  const paymasterAddress = await paymaster.getAddress();
  console.log("✅ PrivacyPaymaster deployed at:", paymasterAddress);

  // Fund paymaster with ETH for gas sponsorship
  console.log("💰 Funding paymaster with 1 ETH...");
  const fundTx = await deployer.sendTransaction({
    to: paymasterAddress,
    value: ethers.parseEther("1.0")
  });
  await fundTx.wait();

  // Add deposit to EntryPoint
  console.log("💰 Adding deposit to EntryPoint...");
  const depositTx = await paymaster.addDeposit({ value: ethers.parseEther("0.5") });
  await depositTx.wait();
  console.log("✅ Paymaster funded and deposited\n");

  // ============================================
  // STEP 4: Deploy SimplePrivacyAccount (Implementation)
  // ============================================
  
  console.log("📝 Step 4: Deploying SimplePrivacyAccount (Implementation)...");
  const SimplePrivacyAccount = await ethers.getContractFactory("SimplePrivacyAccount");
  const accountImpl = await SimplePrivacyAccount.deploy(privacyTreeAddress);
  await accountImpl.waitForDeployment();
  const accountImplAddress = await accountImpl.getAddress();
  console.log("✅ SimplePrivacyAccount implementation deployed at:", accountImplAddress, "\n");

  // ============================================
  // STEP 5: Deploy AccountFactory
  // ============================================
  
  console.log("📝 Step 5: Deploying AccountFactory...");
  const AccountFactory = await ethers.getContractFactory("AccountFactory");
  const factory = await AccountFactory.deploy(
    accountImplAddress,
    config.entryPoint,
    privacyTreeAddress
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("✅ AccountFactory deployed at:", factoryAddress, "\n");

  // ============================================
  // STEP 6: Deploy CrossChainRouter
  // ============================================
  
  console.log("📝 Step 6: Deploying CrossChainRouter...");
  const CrossChainRouter = await ethers.getContractFactory("CrossChainRouter");
  const router = await CrossChainRouter.deploy(lzEndpoint);
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("✅ CrossChainRouter deployed at:", routerAddress, "\n");

  // ============================================
  // STEP 7: Initial Configuration
  // ============================================
  
  console.log("⚙️  Step 7: Configuring contracts...\n");

  // Configure CrossChainRouter with current chain
  console.log("🔧 Adding current chain to router...");
  const addChainTx = await router.addChain(
    chainId,
    getLzChainId(chainId), // Convert to LayerZero chain ID
    privacyTreeAddress
  );
  await addChainTx.wait();
  console.log("✅ Chain added to router");

  // Update gas price for current chain
  const gasPrice = await ethers.provider.getFeeData();
  console.log("🔧 Updating gas price in router...");
  const updateGasTx = await router.updateGasPrice(
    chainId,
    gasPrice.gasPrice || ethers.parseUnits("50", "gwei")
  );
  await updateGasTx.wait();
  console.log("✅ Gas price updated\n");

  // ============================================
  // STEP 8: Create a Test Account
  // ============================================
  
  console.log("📝 Step 8: Creating test account...");
  const salt = 1; // Use salt=1 for first account
  const createAccountTx = await factory.createAccount(deployer.address, salt);
  await createAccountTx.wait();
  
  const testAccountAddress = await factory.getAddress(deployer.address, salt);
  console.log("✅ Test account created at:", testAccountAddress, "\n");

  // Approve test account in paymaster
  console.log("🔧 Approving test account in paymaster...");
  const approveTx = await paymaster.setAccountApproval(testAccountAddress, true);
  await approveTx.wait();
  console.log("✅ Test account approved\n");

  // ============================================
  // DEPLOYMENT SUMMARY
  // ============================================
  
  console.log("═════════════════════════════════════════════════════");
  console.log("🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!");
  console.log("═════════════════════════════════════════════════════\n");

  const deploymentInfo = {
    network: await ethers.provider.getNetwork().then(n => n.name),
    chainId: chainId.toString(),
    deployer: deployer.address,
    contracts: {
      USDC: usdcAddress,
      Verifier: verifierAddress,
      PrivacyMerkleTree: privacyTreeAddress,
      PrivacyPaymaster: paymasterAddress,
      AccountImplementation: accountImplAddress,
      AccountFactory: factoryAddress,
      CrossChainRouter: routerAddress,
      TestAccount: testAccountAddress
    },
    config: {
      entryPoint: config.entryPoint,
      layerZeroEndpoint: lzEndpoint,
      feeRecipient: config.feeRecipient,
      usdcToEthRate: ethers.formatEther(config.usdcToEthRate),
      maxGasPrice: ethers.formatUnits(config.maxGasPrice, "gwei") + " gwei"
    }
  };

  console.log("📋 Deployment Information:");
  console.log(JSON.stringify(deploymentInfo, null, 2));
  console.log("\n");

  // Save deployment info to file
  const fs = require("fs");
  const deploymentPath = `./deployments/deployment-${chainId}.json`;
  
  // Create deployments directory if it doesn't exist
  if (!fs.existsSync("./deployments")) {
    fs.mkdirSync("./deployments");
  }
  
  fs.writeFileSync(
    deploymentPath,
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log("💾 Deployment info saved to:", deploymentPath, "\n");

  // ============================================
  // VERIFICATION INSTRUCTIONS
  // ============================================
  
  console.log("═════════════════════════════════════════════════════");
  console.log("📝 NEXT STEPS:");
  console.log("═════════════════════════════════════════════════════\n");
  
  console.log("1️⃣  Verify contracts on block explorer:");
  console.log(`   npx hardhat verify --network <network> ${verifierAddress}`);
  console.log(`   npx hardhat verify --network <network> ${privacyTreeAddress} "${usdcAddress}" "${verifierAddress}" "${config.feeRecipient}"`);
  console.log(`   npx hardhat verify --network <network> ${paymasterAddress} "${config.entryPoint}" "${usdcAddress}"`);
  console.log(`   npx hardhat verify --network <network> ${accountImplAddress} "${privacyTreeAddress}"`);
  console.log(`   npx hardhat verify --network <network> ${factoryAddress} "${accountImplAddress}" "${config.entryPoint}" "${privacyTreeAddress}"`);
  console.log(`   npx hardhat verify --network <network> ${routerAddress} "${lzEndpoint}"\n`);
  
  console.log("2️⃣  Test the system:");
  console.log(`   npx hardhat run scripts/test-system.js --network <network>\n`);
  
  console.log("3️⃣  For multi-chain deployment:");
  console.log(`   - Deploy on other chains`);
  console.log(`   - Configure cross-chain routes in router`);
  console.log(`   - Update privacy tree addresses per chain\n`);
  
  console.log("4️⃣  Fund test account:");
  console.log(`   - Send USDC to: ${testAccountAddress}`);
  console.log(`   - Or use: npx hardhat run scripts/fund-account.js\n`);

  console.log("═════════════════════════════════════════════════════\n");
}

// Helper function to convert chain ID to LayerZero chain ID
function getLzChainId(chainId) {
  const mapping = {
    1n: 101,     // Ethereum
    137n: 109,   // Polygon
    42161n: 110, // Arbitrum
    10n: 111,    // Optimism
    // Add more mappings as needed
  };
  return mapping[chainId] || 10000 + Number(chainId); // Default fallback
}

// Execute deployment
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });