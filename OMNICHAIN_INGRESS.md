# Omnichain Ingress

Bridgeway's production core vault stays single-chain on Base and accounts in USDC. External assets can still flow into the protocol through a frontend routing layer.

## Principle

Any supported user asset may be accepted by the frontend, but the smart vault deposit asset remains Base USDC.

```text
User source asset on supported chain
    -> LI.FI or Socket route
    -> local swap to USDC when needed
    -> CCTP transfer when available
    -> Across or deBridge fallback when needed
    -> Base USDC
    -> BGWVault deposit
    -> internal 70/25/5 allocation across all sleeves
```

The user's source asset does not determine what the vault holds. Once USDC reaches Base, Bridgeway follows the approved sleeve policies.

## Sleeve Allocation After Ingress

- Sleeve A receives its vault allocation in USDC and buys only approved Base-hub assets or routes value into approved spokes through the Sleeve A adapter.
- Sleeve B receives its vault allocation in USDC and deploys only approved yield-capable stablecoin exposures.
- Sleeve C receives its initial approved allocation in USDC and deploys only approved capped alpha strategies.

## Routing Stack

- Frontend route discovery: LI.FI or Socket.
- Preferred USDC transfer rail: Circle CCTP where available.
- Fast bridge fallback: Across or deBridge where suitable.
- Vault chain: Base.
- Vault accounting asset: USDC.

## Safety Boundary

The routing layer is an ingress/egress convenience, not part of vault NAV accounting.

- The vault should not trust frontend quotes for NAV.
- The vault should not hold unapproved routed assets.
- Failed, delayed, or partial routes must resolve before calling `deposit()`.
- Users should receive clear route, slippage, bridge-fee, and destination-chain disclosures before signing.

## Egress

Withdrawals return Base USDC from the vault. The frontend may optionally route that USDC to another chain or asset through the same routing stack after redemption.
