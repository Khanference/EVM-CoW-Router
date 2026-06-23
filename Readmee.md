UniversalCoWRouter

A protocol-agnostic Coincidence-of-Wants matching engine on Ethereum. Using no imports, no OpenZeppelin and ships with a V2 fallback, a V3 fallback, and a Curve fallback, all in one contract, all driven by inline Yul assembly on every hot path.

This is the EVM-native proof-of-concept. The Solana port is where the real work is going. But more on that at the bottom.

---

What this actually does

Most DEX routers are wrappers. They receive a swap, pick the deepest pool, and forward the user's tokens into that pool's bonding curve. The user pays the full LP fee. They pay full price impact. The router collects a referral margin. No value is created. It is pure extraction dressed as convenience.

This contract takes a different position. When a user wants to sell ETH and another user wants to buy ETH in the same block, those two users are counterparties. Neither needs the pool at all. The pool is a matching-of-last-resort, not a first destination. This contract nets them against each other at the AMM's mid-price, charges 0.1% on the notional, and sends the AMM zero volume for that matched portion. Both users beat what they would have gotten going direct. No price impact. No LP fee paid. The protocol captures value it created, not value it extracted.

The unmatched residual routes to whichever AMM is registered for the pair.

---

The numbers, pulled from the contract header and the underlying math

Gas cost on the fully matched path: approximately 63,500 gas including cold ERC-20 account access and two token transfers. A direct Uniswap V3 swap runs 86,000 to 110,000 gas depending on tick crossings. At 87.5% match rate on ETH/USDC, the blended gas per swap is 65,854 versus 86,666 direct: a 24% reduction in gas spend per trade, purely from the matching architecture.

On the V3 fallback path with zero tick crossings: 88,500 gas. On the V2 fallback: 78,000. Every path is cheaper than going direct, because this contract's hot path strips ABI decoding overhead and operates entirely in Yul, and because EIP-1153 transient storage (TLOAD/TSTORE at 100 gas each) replaces a storage-based reentrancy guard that would cost 5,800 gas warm.

The reentrancy guard in the contract: if tload(GUARD_KEY) { revert } then tstore(GUARD_KEY, 1). GUARD_KEY is keccak256("ucr.guard"). Total guard cost: 200 gas. The standard SSTORE-based guard costs 5,800 gas warm. 29x reduction on that one operation alone.

The matching viability check is let do_cow := and(gt(fee_bps, 10), gt(clrP, 0)). This is the derived condition that CoW matching only activates when the registered AMM's fee exceeds the contract's own 0.1% fee, because below that threshold there is no surplus to split. For 0.01% and 0.05% Uniswap pools, the contract routes directly to the AMM without attempting a match.

Breakeven match rate for a 0.30% pool: m greater than 0.001/0.003 = 33.3%. Above that threshold, every user routed through this contract pays less than going to Uniswap V3 directly. At 50 users per block (realistic for ETH/USDC): modeled match rate using lognormal flow distribution is approximately 89%.

---

The AMM registry and how fallback works

Every pair is registered via registerPair(tokenA, tokenB, pool, interfaceType, feeBps). The config packs into a single bytes32 storage slot: pool(160) | itype(8) | fee_bps(16) | flags(8) | adv_sel_bps(16) | pad(48). One SLOAD gives everything. No second read needed.

Three interface types are supported: 0 for V2-style (Uniswap V2, Sushiswap, PancakeSwap, every fork), 1 for V3-style (Uniswap V3, V4 pool interface, Algebra), 2 for Curve-style (StableSwap, CryptoSwap, Frax, Tricrypto). New AMMs that ship with any of these interface patterns work immediately on registration, without a contract upgrade.

For V2 pools, registerPair calls token0() on the pool and compares the result against the canonical t0 (the lower address). If they don't match, the inversion flag is stored in bit 0 of the flags byte. The reserve direction logic in the fallback then uses iszero(xor(zfc, inverted)) to correctly route amount0Out versus amount1Out. No manual flag required from the deployer.

For Curve pools, the fallback uses balance-delta rather than relying on exchange() returning a value, because older Curve pool versions don't return dy. The contract snapshots its tokenOut balance before calling exchange_with_referral(), then snapshots again after. The difference is the output. This works across every Curve version that has ever deployed on mainnet.

The Curve path also tries exchange_with_referral (selector 0x3c157e64) before falling back to standard exchange (selector 0x3df02124). On pools that support it, this captures Curve's integrator referral rebate, approximately 3 basis points on notional routed. Additional protocol revenue on unmatched fallback volume, at zero cost.

---

The matching engine itself

The CoW state per pair lives in two slots. Slot 1 of the contract's storage holds mapping(bytes32 => bytes32) cowState. Each value is int128 netFlow | uint128 clearingPriceQ128, packed into one bytes32. Positive netFlow means pending buy demand for the higher-addressed token. Negative means pending supply.

The clearing price is stored in Q128 format: token_hi per token_lo times 2^128. This format works for all three AMM types. For V2, it's derived from reserves: div(shl(128, rnum), rden). For V3, it's (sqrtPriceX96 >> 32)^2. For Curve, it's dy * Q128 / 1e18 where dy comes from get_dy(i, j, 1e18). The price error from the 32-bit truncation in the V3 path is 4.7e-10 relative, which on a $10,000 trade is a $4.7e-6 error.

On every call, the contract reads transient state first (tload(pkey) at 100 gas) before falling back to persistent storage (sload(skey) at 2,100 gas cold). At 87.5% match rate, the expected SLOAD cost from this ordering is 0.875 times 2,000 gas less per call than the naive approach.

When match_out is nonzero, the contract TSTOREs the updated state to the transient key and SSTOREs to persistent storage. When there's no match, it TSTOREs only. The clearing price cache survives within the transaction for subsequent calls, which is the within-transaction CoW mechanism for searchers batching opposing swaps in a single multicall.

The adverse selection parameter defaults to zero. This is a deliberate departure from the original specification, which set the default to fee_bps/2. At zero, retail users receive the full AMM mid-price with no haircut. The owner can tune this per pair via setAdverseSelection() if on-chain data starts showing informed flow on a specific pair. Until that signal appears, uninformed retail flow gets strictly better than what the original design assumed.

---

The V3 callback architecture and why it's not a vulnerability

V3-style AMMs pull tokens mid-execution. The pool calls back into the router during the swap to receive tokenIn. This creates a reentrancy surface.

This contract solves it with two TSTORE keys. The first, GUARD_KEY = keccak256("ucr.guard"), is set at swap entry and blocks any reentrant swap() call. The second, GUARD_KEY XOR pool_address, is set immediately before the V3 CALL and cleared immediately after. Inside uniswapV3SwapCallback, the only check is if iszero(tload(xor(GUARD_KEY, caller()))) { revert }. The callback is authorized if and only if it comes from the exact pool that was called in this transaction. A different pool, a malicious contract mimicking the callback, anything else: reverts with ERR_UNAUTHORIZED.

Total cost for both guards: 4 TLOAD/TSTORE operations at 100 gas each = 400 gas. A storage-based version of the same protection would cost over 20,000 gas cold.

---

What bots see

Every swap emits a LOG3 with two indexed topics beyond the event signature: the pair_key and a bool indicating whether it was a matched fill or an AMM fallback. The pair_key is keccak256(token_lo ++ token_hi). Any bot can precompute this for any pair before this contract processes that pair even once and subscribe to the filter in advance. The 192 bytes of non-indexed event data carries tokenIn, tokenOut, amountIn, matchedAmount, ammOut, netAmountOut, the clearing price, the registered pool fee, and the fallback pool address. One log read gives complete execution information.

On any revert path, the revert data encodes the relevant storage slots and contract address as an access list hint. Bots that parse the revert data and retry with a warmed access list save approximately 6,800 gas on the second attempt.

The swapCompact entry point accepts uint96 amounts instead of uint256, saving approximately 40 bytes of calldata and 184 gas per call for bots submitting round-number amounts. uint96 covers 79.2 billion tokens at 18 decimals.

---

This is the EVM version. The Solana port is better in almost every dimension.

Since Solana's execution environment is not EVM with different syntax. It's a parallel runtime with an account model, no public mempool, Jito bundle atomicity, and a fee market denominated in microlamports per Compute Unit. Every assumption in this codebase had to be rederived from scratch.
A small snippet being:

The Solana program replaces within-transaction CoW matching with slot-level flow convergence: opposing swap intents from multiple independent users are aggregated across transaction boundaries inside an atomic Jito bundle, netted against each other in FlowState accounts using zero-copy deserialization, and settled against the underlying CLMM (Orca Whirlpools, Raydium CLMM) only for the net residual. The match rate formula at N users per slot is m(N) = 1 minus 0.755 over sqrt(N). At 50 users per slot that's 89.3%. At 100 users, 92.4%.

The fully matched CU cost in the Solana version is approximately 9,340 CU per user versus maybe 55,000 CU for a direct Orca swap. A 50-user bundle at 87.5% match rate consumes 6.4% of the Compute Units that 50 direct swaps would use.

This EVM contract is the substrate that demonstrated the matching mechanics, the AMM registry pattern, the clearing price derivation across interface types, and the fee capture logic in a fully working deployable form. The Solana port takes those mechanics and rebuilds them for a runtime where the netting pool is one full slot deep rather than one transaction deep.

---

Status as of:

The EVM contract compiles under Solidity 0.8.24 with optimizer 200 runs and via-IR enabled using no external dependencies. The Solana program architecture and full CU/economics derivation are complete. Program implementation is in progress.

The EVM code is here as a proof of the underlying mechanism, and if it went live tomorrow on ETH/USDC it would provide better execution than going to Uniswap directly at any match rate above 33.3%.
