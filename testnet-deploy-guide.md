# Testnet Deploy Guide — Fractional Mutual Fund Prototype

Deploys the four contracts (IdentityRegistry, FundShareToken, FundVault,
MockUSDC) to **Base Sepolia testnet only** — play money, no real funds,
nothing touches mainnet. Run this from your iMac terminal.

> **Keys:** you will create a FRESH throwaway wallet for this. Never use a
> mainnet key here, and never paste any private key into chat with me.

## 0. Get the code on your iMac

The prototype is on GitHub at **https://github.com/deevee3/Fraction.git** (pushed 2026-10-17). On your iMac:

```
git clone https://github.com/deevee3/Fraction.git
cd Fraction
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

Go to a Base Sepolia faucet in your browser, paste your address, complete
the check, and claim. Faucet rules change often — test before you trust:

- **https://faucet.quicknode.com/base/sepolia** — tried live on 2026-10-17:
  rejected the claim, now requires a small ETH balance on Ethereum mainnet
  for the wallet itself. Only useful if your wallet already has mainnet ETH.
- Other options (unverified — check their current rules before relying on
  them): the Coinbase Developer Platform faucet, the Alchemy Base Sepolia
  faucet (needs a free Alchemy account), or bridging Sepolia ETH from
  Ethereum Sepolia to Base Sepolia via the official bridge (needs Sepolia
  ETH first, from a Sepolia faucet).

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
Contract → Connect your wallet → `addInvestor`: your address, and `0` for
the expiry (0 = no expiry, per the contract). You hold the COMPLIANCE_ROLE
as deployer, so this works.

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
