# Mutually Assured Destruction (MAD)

`src/MADToken.sol:MADToken` is an immutable ERC-20. Its constructor creates the entire supply and assigns it to `msg.sender`, the immediate deployer. In the IdentityMD custom-token launch this is the launch factory, which then distributes the supply.

| Parameter | Value |
| --- | --- |
| Solidity contract identifier | `MADToken` |
| Token name | `Mutually Assured Destruction` |
| Symbol | `MAD` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`) |
| Constructor ETH value | `0` |
| Initial holder | Immediate deployer (`msg.sender`) |
| Launch chain | Ethereum, chain ID `1` |

## Behavior and assumptions

The requested name does not specify a destruction mechanic. MAD therefore implements ordinary ERC-20 transfers and approvals, with no burn, tax, reflection, rebase, vesting, or other transfer rule. Transfers deliver the exact amount requested. The contract has no owner, roles, pause, blacklist, seizure, external mint, initialization, upgrade, or recovery entry point. `INITIAL_SUPPLY` is the named fixed supply constant; no value is configurable.

The implementation inherits the vendored [OpenZeppelin Contracts v5.0.2 ERC-20](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/ERC20.sol). The inherited internal mint and burn helpers are not exposed at runtime. `_mint` is called only in the constructor. The contract makes no external calls and needs no oracle, router, signer, or maintenance service.

Successful `transfer`, `approve`, and `transferFrom` calls return `true`; invalid calls revert using OpenZeppelin's ERC-6093 custom errors. Zero-value transfers between nonzero addresses succeed and emit `Transfer`. Self-transfers preserve balances. Transfers to the zero address and approvals for a zero-address spender revert. Finite allowances decrease when spent; `type(uint256).max` denotes an unlimited allowance and is not decreased. `approve` replaces the existing allowance and emits `Approval`; allowance spending does not emit `Approval` in this implementation, so integrations should query `allowance` directly. See the [ERC-20 standard](https://eips.ethereum.org/EIPS/eip-20).

## Build and verification

Run from this repository's root with Foundry and Solidity **0.8.26** installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x0cd177696de5627e8cf6a905adbb3bb17668aef8c8887035c6357c971f26534b forge test
forge fmt --check
sha256sum -c lib/SHA256SUMS
```

All source and test dependencies are included under `lib/` as ordinary files, with licenses and provenance in `lib/README.md`. No dependency installation, RPC connection, credentials, environment configuration, FFI, filesystem permissions, or submodules are needed. The fuzz seed above is a test-run option; tests themselves do not read or change environment variables. With the pinned compiler available, the project builds without network access.

`foundry.toml` pins Solidity 0.8.26, the Cancun EVM target, optimizer enabled with 200 runs, and `bytecode_hash = "none"`. It configures 512 cases per fuzz test and 128 invariant runs of 64 calls. The tests cover:

- Metadata, exact supply, mint events, and EOA versus factory deployment.
- Exact distribution and claim amounts, and both directions of token transfers involving a simulated pool account.
- Zero, full-supply, self, and maximum-value transfers; rejection of invalid recipients and insufficient balances.
- Approval replacement/revocation, delegated transfers, finite/unlimited allowances, unauthorized spending, and transaction rollback after failure.
- Rejection of mint, burn, admin, and upgrade selectors from both the deployer and an unrelated caller; continued holder transfers afterward.
- Randomized success/failure cases and stateful conservation across transfers, approvals, and delegated transfers among four holders.

The local launch fixture tests the token's transfer behavior; it does not simulate Uniswap pricing or liquidity settlement. The supplied protected integration tests also require the launch platform's factory, pool infrastructure, and resolved manifest and run separately in that platform. No launch manifest or application contract is part of this deliverable.

Local verification completed with the pinned compiler and the seed above: `forge build`, `forge test`, and `forge fmt --check` passed. Foundry reported 33 passing test entries and no failures, including five fuzz tests with 512 cases each and a stateful campaign checking both invariants over 8,192 calls with no reverts. All vendored checksums matched. Artifact inspection confirmed no external library links, no constructor arguments, metadata hashing disabled, and no reachable `DELEGATECALL`, `CALLCODE`, or `SELFDESTRUCT` under the supplied floor's opcode scan.

## Deployment and responsibilities

The launch deployer should use the creation bytecode from `out/MADToken.sol/MADToken.json` with no appended arguments and no ETH. `forge inspect src/MADToken.sol:MADToken bytecode` also outputs that bytecode. No linking, initializer, or follow-up configuration is required. Verify the constructor mint event and that `totalSupply()` is `10^27` and the deploying factory holds the entire supply immediately after construction, before distribution. There are no constructor calls to external contracts.

The factory is responsible for launch allocations and liquidity. The supplied launch policy assigns 10% to its Merkle distributor, 80% to liquidity, and the remaining 10% to `0xd6302976e590b9b947da8774b7f1246164e0ce98`. Its pair is IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`; the supplied pool fee is `12500`, tick spacing `60`, and opening market cap `3500000000000000000000` paired-token base units. These are platform settings, not constructor inputs or token logic. The launch platform prepares its manifest and computes the opening pool price; this project neither opens the pool nor performs allocations itself.

### After launch

There are no owner setters or operational roles to configure. The launch operator handles deployment, source verification, distribution, pool creation, and publishing the deployed address. Holders control their balances and approvals. Wallet integrations should use bounded approvals where possible and revoke an existing allowance to zero before replacing it to reduce the standard ERC-20 allowance-change race. Unlimited approvals allow the chosen spender to spend future balances too.

Transfers to contracts that cannot return tokens, including the token contract itself, can permanently strand balances; there is no recovery administrator. The token rejects ordinary ETH payments and has no ETH withdrawal path. Deployment is immutable, so changes require a new contract and voluntary migration. Local tests and source review do not replace the launch platform's independent adversarial review. No deployment, broadcast, Slither, or Mythril execution is included in the local verification.
