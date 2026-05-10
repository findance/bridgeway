# Continuing Bridgeway in VSCode with Claude

## What you have right now

This folder (the one you selected as the Bridgeway workspace) contains:

- `SUMMARY.md` — full design summary + honest review of the chat
- `VSCODE_SETUP.md` — this file
- `contracts/` — where the Solidity will live
- `docs/` — for whitepaper drafts, notes, etc.

The v10 contract source from the previous chat needs to be dropped in here as a clean file — the version pasted into the chat was truncated in the import lines. Either paste it from your previous Claude session into `contracts/BridgewayAutomationWrapper.sol`, or ask me to reconstruct it from the design and I'll write a fresh v10 implementation.

## Step 1 — Install the Claude Code VSCode extension

1. Open VSCode.
2. Open the Extensions sidebar (`Cmd+Shift+X` on Mac, `Ctrl+Shift+X` on Windows/Linux).
3. Search for **Claude Code** by Anthropic.
4. Click **Install**.

## Step 2 — Open this folder in VSCode

`File → Open Folder…` and pick the Bridgeway folder you selected here. The Claude extension automatically picks up the workspace as its working directory.

## Step 3 — Sign in and start a session

- Click the Claude icon in the sidebar (or use `Cmd+Esc` / `Ctrl+Esc`).
- Sign in with the same Anthropic account you're using here.
- The first thing it'll see is `SUMMARY.md`. You can paste:

  > Read SUMMARY.md, then scaffold a Hardhat project around contracts/BridgewayAutomationWrapper.sol with mocks, tests, and a deploy script for Arbitrum Sepolia.

  …and it'll go from there.

## Step 4 — Recommended first prompts in VSCode

The summary captures everything from the chat, so you don't have to re-explain. A few useful starting prompts:

- **Compile check**: "Compile the contract and show me any errors. Set up Hardhat from scratch if it's not already there."
- **Test scaffolding**: "Write a Hardhat test suite covering: 6-way fee split correctness, monthly snapshot rollover, hourly vs daily buyback gas branch, blacklist, pause."
- **Deploy script**: "Write `scripts/deploy.js` that deploys the UUPS proxy to Arbitrum Sepolia using `@openzeppelin/hardhat-upgrades`, with a `.env.example` listing required keys."
- **Mock contracts**: "Generate mock implementations of Enzyme vault, Camelot router, Chainlink price feed, USDC, and BGW for local testing."

## Step 5 — Before you run anything that signs

The VSCode extension can edit files and run `npx hardhat compile` / `npx hardhat test` locally. Anything that broadcasts a transaction (deploy, upgrade, register on Chainlink) needs your private key — keep that in `.env` (which should be gitignored), and only run the deploy command yourself when you're ready.

## Things to set up outside VSCode

These require a browser wallet (MetaMask) and can't be done from inside Claude:

- Get Arbitrum Sepolia ETH from a faucet (e.g. faucet.quicknode.com/arbitrum/sepolia)
- Get an Alchemy or Infura RPC URL for Arbitrum Sepolia
- Get an Arbiscan API key (free) for contract verification
- Eventually: register at automation.chain.link and create the Enzyme vault at app.enzyme.finance

## Important — read SUMMARY.md before you keep building

The "Honest Design Review" section flags real issues (regulatory, Ondo restrictions, audit cost) that the previous chat didn't fully address. Worth reading before sinking more hours in.
