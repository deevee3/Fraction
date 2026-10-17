# Fractional Mutual Fund — Tokenization Prototype

A Foundry prototype for tokenizing **fractional mutual fund shares** on Base:
an allowlisted ERC20 share token plus a subscription/redemption vault priced
at NAV.

> **PROTOTYPE — NOT FOR MAINNET.**
> This code is unaudited, has no legal standing, and does not satisfy any
> securities regulation. Fund shares are securities: a real deployment needs a
> registered transfer agent, broker-dealer distribution, qualified custody, a
> licensed KYC/AML provider, and securities counsel. See
> [Path to production](#path-to-production).

## Architecture

```
                        ┌─────────────────────┐
                        │  IdentityRegistry    │  KYC allowlist (COMPLIANCE_ROLE)
                        │  isVerified(account) │  expiry + flag support
                        └─────────┬───────────┘
                                  │ consulted by
                 ┌────────────────┼────────────────┐
                 ▼                ▼                ▼ (mint/burn)
        ┌────────────────┐ ┌──────────────┐ ┌──────────────┐
        │ FundShareToken │ │  FundVault   │ │   MockUSDC   │
        │ ERC20 "GFFS"   │◄┤ subscribe /  │ │  6-decimal   │
        │ _update gating │ │ redeem @ NAV │ │  demo only   │
        │ freeze / force │ │ NAV_UPDATER  │ └──────────────┘
        │ transfer / pause│ └──────────────┘
        └────────────────┘
```

**How money flows:**

1. Compliance verifies an investor in `IdentityRegistry` (with KYC expiry).
2. Investor approves the vault, calls `subscribe(amount)` — vault pulls
   stablecoin and mints fractional shares:
   `shares = depositAmount * 1e18 / navPerShare`.
3. `FundShareToken` gates **every** balance movement (transfers, mints,
   burns) on both parties being verified. Frozen accounts can't move.
4. Investor calls `redeem(shares)` — vault burns shares, pays stablecoin:
   `payout = shares * navPerShare / 1e18`.
5. The NAV updater publishes new NAVs (`NavUpdated` events carry old/new).
   Admin can `withdrawReserve` to move cash to the off-chain fund manager.

**NAV convention:** `navPerShare` is denominated in **stablecoin base units
per share** (e.g. `$25.00` in 6-decimal USDC = `25_000_000`). Shares are
18-decimal. Integer division truncates in the fund's favor by dust.

## Contracts (`src/`)

| Contract | Purpose |
|---|---|
| `IdentityRegistry.sol` | KYC allowlist. `COMPLIANCE_ROLE` adds/removes/flags investors; `isVerified` checks verified + unflagged + unexpired. |
| `FundShareToken.sol` | ERC20 (18 decimals) "Glenride Fractional Fund Share" / GFFS — **placeholder name**. `_update` hook gates all movements on verification; `TRANSFER_AGENT_ROLE` can freeze, `forceTransfer` (freeze-bypassing, verification still required, pause still enforced), mint, burn. `DEFAULT_ADMIN_ROLE` can pause. |
| `FundVault.sol` | Subscribe/redeem engine at NAV. `NAV_UPDATER_ROLE` sets NAV (must be > 0). `ReentrancyGuard` + `SafeERC20` + checks-effects-interactions. Admin-only `withdrawReserve`. |
| `MockUSDC.sol` | 6-decimal mock stablecoin. Open mint. **Demo only — never mainnet.** |

## Build & test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
forge build
forge test
```

29 tests covering: allowlist gating (unverified can't receive/send/mint),
freeze + unfreeze, `forceTransfer` (bypasses freeze, still needs verified
parties), pausing, subscribe/redeem math at NAV, NAV-update repricing,
access-control reverts on every role, redemption beyond reserve, and an
end-to-end subscribe → NAV-up → redeem flow.

## Deploy (Base Sepolia testnet ONLY)

```bash
cp .env.example .env   # fill in; TESTNET key only, never commit .env
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify
```

The script deploys `MockUSDC` (unless `STABLECOIN_ADDRESS` is set), then
`IdentityRegistry` → `FundShareToken` → `FundVault`, and grants the vault
`TRANSFER_AGENT_ROLE` so it can mint/burn. The deployer initially holds
**every** admin role — the script prints the reassignment checklist:
hand `COMPLIANCE_ROLE`, `TRANSFER_AGENT_ROLE`, `NAV_UPDATER_ROLE`, and
`DEFAULT_ADMIN_ROLE` to their real operators (multisigs) before any demo
that matters.

Chain IDs: Base mainnet `8453` (do NOT deploy here), Base Sepolia `84532`.

## Design decisions (for the future auditor)

- **NAV in base units, not scaled by 1e18.** An earlier draft stored NAV as
  base-units × 1e18; the test suite caught a 1e18 pricing error. Base units
  match how price feeds report and leave exactly one scaling factor.
- **Mint/burn gating is asymmetric by necessity.** "Gate both parties"
  can't apply to the zero address, so mints check only the receiver and
  burns only the sender. Documented in NatSpec.
- **`forceTransfer` bypasses freeze but not pause or verification.**
  Rationale: a legal forced transfer must work against a frozen account
  (that's the point), but an unverified recipient or a global emergency
  pause still blocks it.
- **Instant settlement at current NAV.** Real mutual funds settle T+1 at a
  forward price. This prototype prices at the current NAV for simplicity —
  a known deviation, flagged for production design.
- **No upgradeability.** Contracts are immutable; the registry address is
  `immutable` in the token. Upgrades (UUPS/proxy) are a production call
  with their own trust tradeoffs — deliberately out of scope here.

## Path to production

- [ ] **Independent security audit** of all contracts (this is the
      credibility purchase — budget $30k–$100k+).
- [ ] **Securities counsel**: fund structure ('40 Act), transfer-agent
      agreements, broker-dealer distribution, state Blue Sky.
- [ ] **Registered transfer agent** holding `TRANSFER_AGENT_ROLE`
      (multisig, never an EOA); **qualified custodian** for reserves.
- [ ] **Licensed KYC/AML provider** feeding `IdentityRegistry`
      (expiry + flagging already modeled).
- [ ] **NAV oracle / fund-accountant feed** replacing the human
      `NAV_UPDATER_ROLE`; define forward-pricing and T+1 settlement.
- [ ] Replace `MockUSDC` with a real, redeemable stablecoin; add
      allowlisted redemption rails (wire/ACH off-ramps).
- [ ] Operational runbooks: pause criteria, key rotation, incident
      response, and a production launch checklist per platform.
