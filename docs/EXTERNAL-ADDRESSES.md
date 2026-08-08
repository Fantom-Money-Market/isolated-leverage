# External Protocol Addresses (Sonic mainnet)

> **Reading their source:** `node scripts/fetch-verified-sources.mjs` downloads the verified
> Solidity for every contract below into `external-sources/` (gitignored — regenerate as
> needed). It follows proxies automatically, so the logic contracts land as
> `<name>-impl/`. Needs a free Etherscan API key in `.env` as `SONICSCAN_API_KEY`.

Every third-party contract the Stratus/LendMore stack integrates with, grouped by venue.
All addresses are Sonic mainnet — the local fork inherits them unchanged, so this list is
valid for both environments. Our own deployments (factories, vaults, routers, lens,
Tarot pools) are NOT listed here; those are per-deploy and live in `fork-ui/*.json`.

> Note on position custody: we use **no NFT position manager** on Sonic. The Shadow vault
> mints/burns positions directly on the pool (Ramses-style, gauge tracks position hashes);
> Metropolis DLMM liquidity is ERC-1155 per-bin balances held by the vault; the Beets
> position is a plain ERC-20 BPT. An NFPM only enters the picture for a future
> Aerodrome Slipstream integration.

## Shadow (CL venue — USDC.e/wS market)

| Contract | Address | Role |
|---|---|---|
| USDC.e/wS pool (tickSpacing 50) | `0x324963c267C354c7660Ce8CA3F5f167E05649970` | The CL pool the vault LPs into; also the wS/USD price source for the frontend |
| GaugeV3 (for that pool) | `0xe879d0E44e6873cf4ab71686055a4f6817685f02` | SHADOW emissions staker — vault positions earn via `periodEarned`/`getReward` (weekly periods; on the fork, re-notify after time jumps cross a week boundary) |
| Voter | `0x9F59398D0a397b2EEB8a6123a6c7295cB0b0062D` | ve(3,3) voter — impersonated on the fork to `notifyRewardAmount` on the gauge |

## Beets / Balancer v3 (stS/wS market)

| Contract | Address | Role |
|---|---|---|
| Beets V3 Vault (singleton) | `0xbA1333333333a1BA1108E8412f11850A5C319bA9` | All liquidity ops go through its `unlock` transient-accounting callback; never pull tokens from it directly on the fork (desyncs reserves) |
| stS-wS BPT | `0x75b000584a7d86fb3ef5e15ba26f4c52b41be0e9` | The pool token our adapter wraps 1:1 |
| Gauge (Curve-style) | `0xaE647ea922D392cC825c51967382940A30893f6D` | BEETS emissions staker — adapter auto-stakes BPT, harvests via `claim_rewards`; also the BPT funding source on the fork |

## Metropolis / DLMM (wS/USSD market)

| Contract | Address | Role |
|---|---|---|
| LBFactory | `0x39D966c1BaFe7D3F1F53dA4845805E15f7D6EE43` | Pair discovery (`getAllLBPairs`) at vault creation |
| wS/USSD LBPair (binStep 10) | `0x361F55337074ae43957204CB30fFBAbbCe4Fb837` | The pair the vault mints/burns bins on (ERC-1155); has the live METRO hook |
| LBHooksMCRewarder (hook clone) | `0x0a377447D9D0d900B56C4BE5AbD332B873f6341e` | METRO staker/rewarder — vault claims via `claim(vault, ids)`; pays from real balance (MC `claim`), **never** flip the MasterChef mint flag on the fork |
| LBHooksMCRewarder implementation | `0xd7182dc736Cd322CA03312127d5291a5aF2fa610` | Verified source for the clone above |
| MasterChef (proxy) | `0x1a5DEd6adCFC64acEDe86151b1f142088C6E03Da` | Emission source feeding the hook (pid **131**, ~0.0076 METRO/s); holds the METRO it pays out |
| MasterChef implementation | `0x5B792016e9338353ae2b673c2eebdf26916cc906` | MasterChefV2 behind the proxy |
| METRO/wS LBPair (binStep 100) | `0xf2088eB2d7Bdc2d25C02a5B731f30CdA52862010` | Deepest METRO market — frontend derives METRO/USD from its active bin |

## Tokens

| Token | Address | Decimals |
|---|---|---|
| wS | `0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38` | 18 |
| USDC.e | `0x29219dd400f2Bf60E5a23d13Be72B486D4038894` | 6 |
| SHADOW | `0x3333b97138D4b086720b5aE8A7844b1345a33333` | 18 |
| stS | `0xE5DA20F15420aD15DE0fa650600aFc998bbE3955` | 18 |
| BEETS | `0x2D0E0814E62D80056181F5cd932274405966e4f0` | 18 |
| USSD | `0x000000000eCcFf26B795F73fb0A70d48da657fEf` | 18 |
| METRO | `0x71E99522EaD5E21CF57F1f542Dc4ad2E841F7321` | 18 |

## Fork-only helpers (impersonated / used by scripts, not protocol integrations)

| Contract | Address | Role |
|---|---|---|
| wS/USSD LBPair (binStep 20) | `0x9e81415250996E5cE50B3E3FD99EE9964Dd53008` | Deploy-script funding source for DLMM seeds (a *different* pair than the target, to avoid the round-trip funding bug) |
| Shadow USDC.e/wS pool (same as above) | `0x324963c267C354c7660Ce8CA3F5f167E05649970` | Impersonated as wS/USDC.e whale for funding lenders/users |
