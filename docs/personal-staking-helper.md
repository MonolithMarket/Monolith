# Personal staking helpers for CoinDAOs

Users can deposit a Monolith Token into its Vault and stake the resulting
sToken in its DAO's existing GOV rewards pool in one transaction, after
approving Token. The sToken continues to earn vault yield while staked; GOV
accrues according to the pool's funded reward schedule.

One helper factory serves the eligible DAOs registered by one fixed
CoinDAOFactory on that chain. It deploys one shared implementation and creates
one EIP-1167 helper clone per owner and DAO on first use. No helper-factory
redeployment or manual coin registration is needed for new eligible DAOs.

## Deployment and registry

Deploy `PersonalStakingHelperFactory(coinDAOFactory)` once, using a verified
CoinDAOFactory v2 deployment. The constructor deploys the shared helper
implementation automatically. It checks that the registry address contains
code; the deployer must verify that it is the intended authentic factory.

The factory reads the registry's `deployments(daoId)` record to select the
vault and rewards pool. Only entries whose `stakingToken` equals the nonzero
`vault` are accepted. DAOs that stake Token directly are rejected. Unknown
IDs revert through the registry lookup. Each helper reads Token from its
vault and GOV from its pool during initialization.

Use the ID emitted by **CoinDAOFactory's** `CoinDAODeployed` event, or the
index in its `deployments` array. This is not the Monolith market factory's
separate deployment index.

The adapter matches the fourteen-address public getter in
[CoinDAOFactory v2](https://github.com/MonolithMarket/GovernanceFactory/blob/be1b426577d17edba960ce28363d39dde3acbcb4/src/CoinDAOFactory.sol#L107),
commit `be1b426577d17edba960ce28363d39dde3acbcb4`. It requires no changes to that
factory. A different governance factory or incompatible registry layout
requires a separate helper-factory deployment.

## Ownership and market binding

Existing StakingRewards pools credit `stake(amount)` to `msg.sender`. Each
personal helper therefore holds its owner's separate pool position. A user
who enters two DAOs has two helpers, both created by the same shared factory.

Each clone's owner, vault, pool, Token and GOV are configured once during
atomic creation and initialization. Only the factory can initialize a clone,
and reinitialization is blocked. The shared implementation is locked against
initialization. Later deposits reuse the helper's stored market configuration.

The registry and implementation addresses in the helper factory are immutable.
There is no administrator, registry setter, upgrade path, ownership transfer
or arbitrary-call function. All withdrawals, rewards and recovered tokens go
to the helper's fixed owner, which may be an EOA or a smart account.

## User flow

1. Approve the DAO's Token to the shared helper factory. Each Token has its own
   allowance. Approval is a separate transaction unless the user's account
   can batch calls; this version does not add permit support.
2. Call `factory.depositAndStake(daoId, assets, minShares)`. The factory creates
   the user's helper if necessary and pulls Token directly from the caller to
   that helper. The helper deposits exactly that amount and stakes the shares
   returned by the Vault.
3. Read `factory.helperOf(daoId, owner)` to find the user's helper. Use its
   `stakedShares()` and `earned()` to display the position and claimable GOV.

Owner actions on the helper require no DAO argument because its market is
already fixed:

| Function | Result |
| --- | --- |
| `claim()` | Claims GOV and transfers its entire loose GOV balance to the owner. |
| `withdraw(shares)` | Unstakes sToken to the owner, retaining vault exposure. |
| `withdrawAndRedeem(shares, minAssets)` | Unstakes and redeems to Token for the owner. |
| `recoverToken(token)` | Returns loose tokens to the owner without touching the staked position. |

Withdrawals do not call `getReward()`, so a failing GOV transfer does not block
either exit route. Accrued GOV remains claimable after withdrawal. The helper
does not bypass failures in the vault, staking pool or Token.

## Minimum outputs and supported contracts

Use the Vault's `previewDeposit` and `previewRedeem` to quote minimum outputs.
Monolith burns `1e16` shares on a vault's first deposit; the helper checks the
actual shares returned by the Vault. A failed minimum, transfer or stake
reverts the whole entry, including helper creation on the first deposit.

Transactions have no expiry. A pending deposit can execute later, including
after a GOV reward period ends. Minimum outputs protect vault conversion
amounts; they do not guarantee a GOV reward rate or execution time.

The helper relies on the registered Monolith Token, Vault and StakingRewards
contracts' transfer and accounting behaviour. Token and GOV must transfer
exact amounts and maintain stable balances; fee-on-transfer and rebasing
tokens are unsupported. The helper does not add balance assertions for
arbitrary implementations.

Token and sToken approvals from the helper are exact and cleared after use.
Factory and helper entry points use reentrancy guards. Pre-existing Token or
sToken donations remain loose and can be recovered only by the helper's owner.
There is no shared user balance ledger or caller-selected payer/beneficiary.

Existing stakes held directly by a user's wallet remain separate. Moving
such a position requires withdrawing it first; this version provides the
Token-to-vault-to-pool entry route. The helper does not fund rewards, change
their rate or compound GOV.

## Tests and dependencies

Initialize the repository submodules before building. OpenZeppelin Contracts
and Contracts Upgradeable are pinned to v5.5.0 in `.gitmodules`, `foundry.lock`
and the corresponding gitlinks. Upgradeable contracts are used by the staking
test fixture only; the helper itself has no upgrade mechanism.

Run the focused suite with:

```sh
FOUNDRY_PROFILE=personal-staking forge test -vv
```

On PowerShell, set `$env:FOUNDRY_PROFILE = 'personal-staking'` before `forge test`.
The profile runs 512 fuzz cases and 128 invariant runs of 64 calls. The
invariant covers three owners across two DAOs, checking separate stakes,
market bindings and full backing during deposits, exits, claims and yield.
Unit tests cover the registry getter ABI, future DAO registration, approval
isolation, unsupported DAO rejection, initialization, slippage rollback,
donations, transfer failures and reentrancy. Dynamic test linking is disabled
for expected-constructor-revert compatibility with Foundry v1.8.5.

The fixture deploys this repository's actual Vault and simulates lender
interest and ERC20 assets. `fixtures/CoinDAOFactoryRegistry.sol` independently
copies the pinned upstream Deployment layout and public array getter, so the
struct-returning adapter is tested against Solidity's generated flat-address
getter. It is a registry fixture, not a complete CoinDAO launch simulation.

`fixtures/StakingRewards.sol` copies
[GovernanceFactory's staking implementation](https://github.com/MonolithMarket/GovernanceFactory/blob/be1b426577d17edba960ce28363d39dde3acbcb4/src/StakingRewards.sol)
at the same commit, blob `7c2306c9a81a502ce1053fe32c38f69426433273`. Its only
source change is lowering the compiler pragma from `^0.8.26` to `^0.8.24` to
use Monolith's compiler alongside the real Vault. These tests do not establish
live registry or pool state, and this change does not deploy any contracts.
