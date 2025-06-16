# Monolith Protocol

Monolith is an autonomous single-collateral stablecoin protocol factory. The protocol features a unique dual debt system for deployed stablecoins with free (redeemable) and paid (non-redeemable) debt mechanisms.

## Development

Built using the Foundry framework. To get started:

```shell
# Build
forge b

# Run tests
forge t
```

## Core Components

The protocol consists of three main contracts:

- **Factory**: Allows users to create new Monolith stablecoins
- **Lender**: The main user entry point contract for each stablecoin, handling borrowing, liquidations, redemptions, and debt management
- **Vault**: A yield-bearing tokenized vault for Monolith stablecoins implementing the ERC4626 standard

## Key Features

### Dual Debt System

Borrowers are assigned a non-redeemable status by default. They can opt to convert to a redeemable status. The status can be changed at any time.

- **Redeemable Borrowers**: They offer their collateral to be redeemed by anyone. Redeemers also repay some of their debt. These borrowers are offered a 0% borrow rate (free debt).
- **Non-Redeemable Borrowers**: They are fully protected from redemptions. They pay a variable borrow rate (paid debt) in exchange for this protection.

### Interest Rate Mechanism
The interest rate is always 0% for redeemable borrowers.

Non-redeemable borrowers are required to pay a variable borrow rate.

The rate is determined by the ratio of free debt to total debt.

When free debt ratio is higher than target, this signals that the current interest rate is too high. The rate is then exponentially reduced to incentivize more borrowers to start paying interest and opt out of redemptions.

When free debt ratio is lower than target, this signals that the current interest rate is too low. The rate is then exponentially increased to incentivize some borrowers to opt into redemptions or repay their debt.

When free debt ratio is within the target range, the interest rate remains constant at the last rate.

### Liquidations & Bad Debt Management
We use traditional discounted-price liquidations based on collateral price oracle.

If the value of a positions's debt exceeds the value of collateral * collateral factor, debt can be fully or partially repaid by any liquidator in exchange for collateral + liquidation incentive.

After each liquidation, the protocol makes an attempt to write off the remaining debt in case the debt value exceeds the value of the collateral (regardless of the collateral factor).

Write-offs simply redistribute the remaining debt and collateral equally among all other borrowers (regardless of their redemption status). This causes borrowers to absorb bad debt. Write-offs can also be triggered independently of liquidations.

### Redemptions

Only borrowers who have opted into redemptions are subject to have their collateral be redeemed.

Redemptions cause eligible borrowers collateral to be reduced by the same dollar value as their debt is reduced minus a fee paid by redeemers to borrowers. Redemptions are distributed pro-rata among all eligible borrowers.

### Vault

Stablecoin holders can stake in the Vault to earn a portion of interest paid by non-redeemable borrowers.

Vault yield is capped by the borrow rate of non-redeemable borrowers but may be lower depending on the free debt ratio.

Excess interest is added to the protocol's reserve which is only accessible by the protocol owner. Additionally, a fee can be charged on the Vault yield up to a maximum of 25%.

### Immutability Deadline

A temporary operator role is added to the protocol to allow for adjusting certain protocol parameters after deployment. However, this role cannot upgrade the protocol or make changes beyong the predetermined parameters.

This role is automatically revoked after a set amount of time. This provides a balance between initial flexibility and long-term immutability. Only the fee switch is exempt from this deadline.
