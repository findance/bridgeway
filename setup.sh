#!/usr/bin/env bash
# Bridgeway Protocol — dev environment bootstrap
# Run once after cloning: bash setup.sh

set -e

echo "=== Bridgeway Protocol Setup ==="

# 1. Check forge is installed
if ! command -v forge &> /dev/null; then
  echo "Installing Foundry..."
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
fi

echo "Forge version: $(forge --version)"

# 2. Install dependencies
echo "Installing OpenZeppelin contracts..."
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit

echo "Installing Chainlink contracts..."
forge install smartcontractkit/chainlink-brownie-contracts --no-commit

# 3. Copy env template
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env — fill in your addresses before deploying"
fi

# 4. Build
echo "Building contracts..."
forge build

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Fill in .env with real wallet addresses"
echo "  2. Run tests: forge test"
echo "  3. Deploy to Arbitrum testnet (Sepolia): forge script scripts/deploy/01_DeployTokens.s.sol --rpc-url \$ARBITRUM_TESTNET_RPC --broadcast"
echo "  4. Deploy to mainnet ONLY after audit"
