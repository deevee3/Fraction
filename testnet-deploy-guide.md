# Testnet Deploy Guide — Fractional Mutual Fund Prototype

Deploys the four contracts (IdentityRegistry, FundShareToken, FundVault,
MockUSDC) to **Base Sepolia testnet only** — play money, no real funds,
nothing touches mainnet. Run this from your iMac terminal.

> **Keys:** you will create a FRESH throwaway wallet for this. Never use a
> mainnet key here, and never paste any private key into chat with me.

## 0. Get the code on your iMac

The prototype currently lives only in my workspace — it has not been
pushed to GitHub yet. Tell me which repo to push it to (I'll mirror
Glenride org + deevee3 per your mirror rule), then:

```
git clone <repo-url>
cd fractional-mutual-fund-prototype
```

## 1. Install Foundry

```
curl -L https://foundry.paradigm.xyz | bash
```

This downloads the installer. Close the terminal and open a new one (so the
new PATH takes effect), then:

```
foundryup
```

Installs `forge` (build/test), `cast` (chain CLI), `anvil` (local chain).
Check it worked:

```
forge --version
```

## 2. Create a throwaway testnet wallet

```
cast wallet new
```

Write down the address. The private key stays on your machine — testnet
only, never reuse it for mainnet.

## 3. Claim free test ETH

Go to **https://faucet.quicknode.com/base/sepolia** in your browser,
paste your address, complete the check, and claim.

No account needed, no mainnet balance needed, once per 12 hours.
Reason: deploying contracts costs gas, and testnet ETH is free play money.

Confirm it landed:

```
cast balance <your-address> --rpc-url https://sepolia.base.org
```

## 4. Configure the deploy

```
cp .env.example .env
```

Open `.env` and paste your **testnet** private key into `DEPLOYER_KEY`.
The RPC URL is already set to Base Sepolia (chain ID 84532).
`.env` is gitignored — it will never be committed.

## 5. Deploy

```
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
```

This deploys MockUSDC, IdentityRegistry, FundShareToken, FundVault, then
grants the vault the right to mint/burn shares. Copy the four contract
addresses from the output.

## 6. Click through it on the explorer

Open **https://sepolia.basescan.org**, paste each contract address.

**a. Get yourself verified.** On IdentityRegistry → Contract → Write
Contract → Connect your wallet → `addInvestor`: your address, and an expiry
timestamp far in the future, e.g. `1893456000` (2030-01-01). You hold the
COMPLIANCE_ROLE as deployer, so this works.

**b. Get demo stablecoins.** On MockUSDC → Write Contract → `mint`: your
address, `100000000` (that's 100 USDC in 6-decimal base units). Open mint —
anyone can call it.

**c. Approve the vault.** On MockUSDC → `approve`: the vault's address,
`100000000`.

**d. Buy shares.** On FundVault → `subscribe`: `100000000`. At the default
$25 NAV you receive 4 shares (18 decimals).

**e. Sell them back.** On FundVault → `redeem`: the share amount, e.g.
`4000000000000000000` (4 shares). The vault burns shares and pays USDC.

## 7. When you're done

The deployer still holds every admin role — the script prints the
reassignment checklist (compliance, transfer agent, NAV updater, admin to
their real operators/multisigs). For a real demo that matters, do that
step; for clicking around, you can skip it.

## Remember

- **Prototype — not for mainnet.** Unaudited, no legal standing, no
  securities compliance. Fund shares are securities: real deployment needs
  a registered transfer agent, broker-dealer distribution, licensed KYC,
  custody, and counsel.
- Real mutual funds settle T+1 at a forward price; this prototype settles
  instantly. Known deviation, flagged in the README.
