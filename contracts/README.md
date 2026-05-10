# Contracts

Drop the v10 `BridgewayAutomationWrapper.sol` source here from the previous Claude chat. The version pasted in chat had truncated import statements (showing `...` instead of the full path), so paste the complete file from the original source rather than reconstructing from the snippets.

If the original is no longer accessible, ask Claude in VSCode:

> Reconstruct the BridgewayAutomationWrapper v10 contract from the design described in /SUMMARY.md. UUPS upgradeable, OpenZeppelin upgradeable libraries, Chainlink AutomationCompatibleInterface, Camelot router integration, 6-way fee split (45/20/15/10/5/5), monthly buyback snapshot with hourly/daily gas-aware execution, 0.1% ops cut to holdback, blacklist, pause, dynamic price feed decimals.

Mocks for testing should live in `contracts/mocks/`:

- `MockEnzymeVault.sol`
- `MockUSDC.sol` (or use `@openzeppelin/contracts/mocks/ERC20Mock.sol`)
- `MockBGWToken.sol`
- `MockCamelotRouter.sol`
- `MockPriceFeed.sol`
