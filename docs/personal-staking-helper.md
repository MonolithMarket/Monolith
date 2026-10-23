# Personal staking helper for existing rewards pools

The helper lets a user deposit a Monolith Token into its Vault and stake the
resulting sToken in an existing GOV rewards pool in one transaction, after
approving Token. The sToken continues to earn vault yield while staked; GOV
accrues according to the pool's funded reward schedule.

Existing `StakingRewards` pools credit `stake(amount)` to `msg.sender`. A shared
router would own a combined position. Instead, this factory creates one small
EIP-1167 helper per owner, so the pool keeps each user's accounting separate.
No changes to the Vault, pool or governance factory are required.

## Deployment and ownership

This helper supports Monolith's Token, Vault and existing StakingRewards
contracts. Deploy `PersonalStakingHelperFactory(vault, stakingRewards)` once
per verified vault/pool pair. The constructor checks that the pool stakes that
vault, that the Token and GOV addresses contain code, and that GOV is distinct
from Token and sToken. These checks validate wiring, not the authenticity of
arbitrary contracts; the frontend must use a verified deployment for the
intended pair.

The factory deploys one implementation and creates a clone on each owner's
first deposit. It stores the address in `helperOf(owner)` and reuses it for
subsequent deposits. The implementation's contract addresses are immutable and
shared by the clones; each clone has its own owner, storage and pool position.
The implementation is locked against initialization. Clone creation and
initialization are atomic and only the factory can initialize a clone.

There is no administrator, upgrade path, ownership transfer or arbitrary call
function. The owner can be an EOA or a smart account. All withdrawals, rewards
and recovered tokens go to that fixed owner.

## User flow

1. Approve Token to the factory. Approval is a separate transaction unless the
   user's account can batch calls; this version does not add permit support.
2. Call `factory.depositAndStake(assets, minShares)`. The factory pulls Token
   from the caller directly to their helper. The helper deposits exactly that
   amount and stakes exactly the newly minted shares.
3. Read `factory.helperOf(owner)` to find the user's helper. Use the helper's
   `stakedShares()` and `earned()` for the displayed position and claimable GOV.

Owner actions on the helper:

| Function | Result |
| --- | --- |
| `claim()` | Claims GOV and transfers its entire loose GOV balance to the owner. |
| `withdraw(shares)` | Unstakes sToken to the owner, retaining its vault exposure. |
| `withdrawAndRedeem(shares, minAssets)` | Unstakes and redeems to Token for the owner. |
| `recoverToken(token)` | Returns loose tokens to the owner without touching the staked position. |

Withdrawals do not call `getReward()`, so a failing GOV transfer does not block
either exit route. Accrued GOV remains claimable after withdrawal. The helper
does not bypass failures in the vault, staking pool or underlying token.

Use the Vault's `previewDeposit` and `previewRedeem` to quote amounts, then set
the user's minimum output. Monolith burns `1e16` shares on a vault's first
deposit; the helper checks the actual shares returned by the Vault. A failed
minimum, transfer or stake reverts the whole entry, including the clone
creation when it is the first deposit.

Transactions have no expiry. A pending deposit can execute later, including
after a GOV reward period ends. Minimum outputs protect the vault conversion
amounts; they do not guarantee a GOV reward rate or execution time.

## Scope and protections

- One fixed pair per factory; one fixed owner per helper. There is no shared
  user balance ledger and no caller-selected payer or beneficiary.
- Token and sToken approvals from the helper are exact and cleared after use.
  Factory and helper entry points use reentrancy guards.
- Deposits use the requested Token amount and stake only the shares returned
  by the Vault. Pre-existing Token or sToken donations remain loose and can be
  recovered only by the owner.
- Token and GOV must transfer exact amounts and have stable balances. Rebasing
  and fee-on-transfer tokens are unsupported, consistent with the pool. The
  helper relies on the fixed contracts' transfer and accounting behaviour;
  it does not add balance assertions to support arbitrary implementations.
- Existing stakes held directly by the user's wallet remain separate. Moving
  such a position requires withdrawing it first; this version only provides
  the Token-to-vault-to-pool entry route.
- Yield and rewards depend on the existing contracts and funded schedules.
  This helper does not fund rewards, change their rate or compound GOV.

## Tests and dependencies

Initialize the repository submodules before building. OpenZeppelin Contracts
and Contracts Upgradeable are pinned to v5.5.0 in `.gitmodules`, `foundry.lock`
and the corresponding gitlinks. Upgradeable contracts are used by the test
fixture only; the helper itself has no upgrade mechanism.

Run the focused suite with:

```sh
FOUNDRY_PROFILE=personal-staking forge test -vv
```

On PowerShell, set `$env:FOUNDRY_PROFILE = 'personal-staking'` before `forge test`.
The profile runs 512 fuzz cases and 128 invariant runs of 64 calls. It tests
isolated positions, yield and GOV, partial/full exits, slippage rollback,
donations, permissions, initialization, transfer failures and reentrancy.
Dynamic test linking is disabled so expected constructor reverts continue to
the subsequent assertions with the tested Foundry v1.8.5 release.

The fixture deploys this repository's actual `Vault` and simulates its lender
interest and ERC20 assets. `test/personal-staking/fixtures/StakingRewards.sol`
copies [GovernanceFactory's staking implementation](https://github.com/MonolithMarket/GovernanceFactory/blob/be1b426577d17edba960ce28363d39dde3acbcb4/src/StakingRewards.sol)
at commit `be1b426577d17edba960ce28363d39dde3acbcb4`, blob
`7c2306c9a81a502ce1053fe32c38f69426433273`. Its only change is lowering the
compiler pragma from `^0.8.26` to `^0.8.24` to use Monolith's compiler alongside
the real Vault. The tests do not establish the state or wiring of a live pool.

This change adds contracts, documentation and tests. It does not deploy a
factory or connect a frontend to it.
