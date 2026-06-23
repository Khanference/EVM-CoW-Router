pragma solidity ^0.8.24;

contract UniversalCoWRouter {

    address private immutable OWNER;
    address private immutable FEE_RECIPIENT;
    address private immutable REFERRAL;

    mapping(bytes32 => bytes32) private ammConfigs;
    mapping(bytes32 => bytes32) private cowState;

    uint256 private constant Q128 = 0x100000000000000000000000000000000;

    bytes32 private constant GUARD_KEY = keccak256("ucr.guard");

    uint32 private constant ERC20_TRANSFER_FROM = 0x23b872dd;
    uint32 private constant ERC20_TRANSFER      = 0xa9059cbb;
    uint32 private constant ERC20_BALANCE_OF    = 0x70a08231;
    uint32 private constant ERC20_APPROVE       = 0x095ea7b3;
    uint32 private constant ERC20_PERMIT        = 0xd505accf;

    uint32 private constant V2_GET_RESERVES  = 0x0902f1ac;
    uint32 private constant V2_TOKEN0        = 0x0dfe1681;
    uint32 private constant V2_SWAP          = 0x022c0d9f;
    uint32 private constant V3_SLOT0         = 0x3850c7bd;
    uint32 private constant V3_SWAP          = 0x128acb08;
    uint32 private constant CRV_GET_DY       = 0x5e0d443f;
    uint32 private constant CRV_EXCHANGE     = 0x3df02124;
    uint32 private constant CRV_EXCHANGE_REF = 0x3c157e64;

    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    bytes32 private constant SWAP_TOPIC = keccak256(
        "Swap(bytes32,bool,address,address,uint256,uint256,uint256,uint256,uint256,address)"
    );

    uint32 private constant ERR_REENTRANT    = 0xab143c06;
    uint32 private constant ERR_UNAUTHORIZED = 0x82b42900;
    uint32 private constant ERR_NO_PAIR      = 0x22b8b631;
    uint32 private constant ERR_SLIPPAGE     = 0xcf479181;
    uint32 private constant ERR_TRANSFER     = 0x700b0c20;

    constructor(address owner_, address feeRecipient_, address referral_) {
        OWNER         = owner_;
        FEE_RECIPIENT = feeRecipient_;
        REFERRAL      = referral_;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external returns (uint256 amountOut) {
        amountOut = _execute(tokenIn, tokenOut, amountIn, minOut, recipient);
    }

    function swapCompact(
        address tokenIn,
        address tokenOut,
        uint96  amountIn,
        uint96  minOut,
        address recipient
    ) external returns (uint256 amountOut) {
        amountOut = _execute(tokenIn, tokenOut, uint256(amountIn), uint256(minOut), recipient);
    }

    function swapWithPermit(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountOut) {
        assembly {
            mstore(0x00, shl(224, ERC20_PERMIT))
            mstore(0x04, caller())
            mstore(0x24, address())
            mstore(0x44, amountIn)
            mstore(0x64, deadline)
            mstore(0x84, v)
            mstore(0xa4, r)
            mstore(0xc4, s)
            pop(call(gas(), tokenIn, 0, 0x00, 0xe4, 0x00, 0x00))
        }
        amountOut = _execute(tokenIn, tokenOut, amountIn, minOut, recipient);
    }

    function _execute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) internal returns (uint256 amountOut) {
        assembly {
            if tload(GUARD_KEY) {
                mstore(0x00, shl(224, ERR_REENTRANT))
                revert(0x00, 0x04)
            }
            tstore(GUARD_KEY, 1)

            let t0  := tokenIn
            let t1  := tokenOut
            let zfc := 1
            if gt(tokenIn, tokenOut) {
                t0  := tokenOut
                t1  := tokenIn
                zfc := 0
            }

            mstore(0x00, t0)
            mstore(0x20, t1)
            let pkey := keccak256(0x00, 0x40)

            mstore(0x00, pkey)
            mstore(0x20, 0x00)
            let cfg_slot := keccak256(0x00, 0x40)
            let cfg      := sload(cfg_slot)

            let pool    := and(cfg, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            let itype   := and(shr(160, cfg), 0xFF)
            let fee_bps := and(shr(168, cfg), 0xFFFF)
            let flags   := and(shr(184, cfg), 0xFF)
            let adv_sel := and(shr(192, cfg), 0xFFFF)

            let tstate   := tload(pkey)
            mstore(0x00, pkey)
            mstore(0x20, 0x01)
            let skey := keccak256(0x00, 0x40)
            if iszero(tstate) {
                tstate := sload(skey)
            }
            let net_flow := sar(128, tstate)
            let clrP     := and(tstate, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)

            if iszero(clrP) {
                if iszero(pool) {
                    mstore(0x00, shl(224, ERR_NO_PAIR))
                    mstore(0x04, address())
                    mstore(0x24, cfg_slot)
                    revert(0x00, 0x44)
                }

                switch itype

                case 0 {
                    mstore(0x00, shl(224, V2_GET_RESERVES))
                    if iszero(staticcall(5000, pool, 0x00, 0x04, 0x80, 0x60)) {
                        revert(0x00, 0x00)
                    }
                    let r0 := mload(0x80)
                    let r1 := mload(0xa0)
                    let rnum := r1
                    let rden := r0
                    if and(flags, 0x01) {
                        rnum := r0
                        rden := r1
                    }
                    if iszero(rden) { revert(0x00, 0x00) }
                    clrP := div(shl(128, rnum), rden)
                }

                case 1 {
                    mstore(0x00, shl(224, V3_SLOT0))
                    if iszero(staticcall(5000, pool, 0x00, 0x04, 0x80, 0x20)) {
                        revert(0x00, 0x00)
                    }
                    let sqrtP := and(mload(0x80), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    let sp    := shr(32, sqrtP)
                    if gt(sp, 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) {
                        sp := 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
                    }
                    clrP := mul(sp, sp)
                }

                case 2 {
                    let ci := and(shr(1, flags), 0x07)
                    let cj := and(shr(4, flags), 0x07)
                    if iszero(zfc) {
                        let tmp := ci
                        ci := cj
                        cj := tmp
                    }
                    mstore(0x00, shl(224, CRV_GET_DY))
                    mstore(0x04, ci)
                    mstore(0x24, cj)
                    mstore(0x44, 0x0de0b6b3a7640000)
                    if iszero(staticcall(10000, pool, 0x00, 0x64, 0x80, 0x20)) {
                        revert(0x00, 0x00)
                    }
                    let dy := mload(0x80)
                    if gt(dy, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) {
                        dy := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
                    }
                    clrP := div(mul(dy, Q128), 0x0de0b6b3a7640000)
                }

                default { revert(0x00, 0x00) }
            }

            let do_cow := and(gt(fee_bps, 10), gt(clrP, 0))

            let match_in  := 0
            let match_out := 0

            if do_cow {
                mstore(0x00, shl(224, ERC20_BALANCE_OF))
                mstore(0x04, address())
                staticcall(5000, tokenOut, 0x00, 0x24, 0x80, 0x20)
                let inv := mload(0x80)

                if gt(inv, 0) {
                    let raw_out := 0
                    switch zfc
                    case 1 {
                        raw_out := div(mul(amountIn, clrP), Q128)
                    }
                    default {
                        if clrP { raw_out := div(mul(amountIn, Q128), clrP) }
                    }

                    match_out := raw_out
                    if gt(raw_out, inv) { match_out := inv }

                    if and(adv_sel, gt(match_out, 0)) {
                        let haircut := div(mul(match_out, adv_sel), 10000)
                        match_out   := sub(match_out, haircut)
                    }

                    switch zfc
                    case 1 {
                        if clrP { match_in := div(mul(match_out, Q128), clrP) }
                    }
                    default {
                        match_in := div(mul(match_out, clrP), Q128)
                    }

                    if gt(match_in, amountIn) {
                        match_in := amountIn
                        switch zfc
                        case 1 { match_out := div(mul(match_in, clrP), Q128) }
                        default {
                            if clrP { match_out := div(mul(match_in, Q128), clrP) }
                        }
                    }
                }
            }

            mstore(0x00, shl(224, ERC20_TRANSFER_FROM))
            mstore(0x04, caller())
            mstore(0x24, address())
            mstore(0x44, amountIn)
            {
                let ok := call(gas(), tokenIn, 0, 0x00, 0x64, 0x80, 0x20)
                if iszero(ok) {
                    mstore(0x00, shl(224, ERR_TRANSFER))
                    mstore(0x04, address())
                    mstore(0x24, cfg_slot)
                    mstore(0x44, skey)
                    mstore(0x64, tokenIn)
                    revert(0x00, 0x84)
                }
                if returndatasize() {
                    if iszero(mload(0x80)) {
                        mstore(0x00, shl(224, ERR_TRANSFER))
                        revert(0x00, 0x04)
                    }
                }
            }

            let unmatched_in := sub(amountIn, match_in)
            let amm_out      := 0

            if gt(unmatched_in, 0) {
                if iszero(pool) {
                    mstore(0x00, shl(224, ERR_NO_PAIR))
                    mstore(0x04, address())
                    mstore(0x24, cfg_slot)
                    revert(0x00, 0x44)
                }

                switch itype

                case 0 {
                    mstore(0x00, shl(224, V2_GET_RESERVES))
                    if iszero(staticcall(5000, pool, 0x00, 0x04, 0x80, 0x60)) {
                        revert(0x00, 0x00)
                    }
                    let r0 := mload(0x80)
                    let r1 := mload(0xa0)

                    let inverted := and(flags, 0x01)
                    let res_in  := r0
                    let res_out := r1
                    if iszero(xor(zfc, inverted)) {
                        res_in  := r1
                        res_out := r0
                    }

                    let fee_adj := mul(unmatched_in, 997)
                    let num     := mul(fee_adj, res_out)
                    let den     := add(mul(res_in, 1000), fee_adj)
                    if iszero(den) { revert(0x00, 0x00) }
                    amm_out := div(num, den)

                    mstore(0x00, shl(224, ERC20_TRANSFER))
                    mstore(0x04, pool)
                    mstore(0x24, unmatched_in)
                    if iszero(call(gas(), tokenIn, 0, 0x00, 0x44, 0x80, 0x20)) {
                        revert(0x00, 0x00)
                    }

                    let a0out := 0
                    let a1out := amm_out
                    if iszero(xor(zfc, inverted)) {
                        a0out := amm_out
                        a1out := 0
                    }
                    mstore(0x00, shl(224, V2_SWAP))
                    mstore(0x04, a0out)
                    mstore(0x24, a1out)
                    mstore(0x44, address())
                    mstore(0x64, 0x80)
                    mstore(0x84, 0x00)
                    if iszero(call(gas(), pool, 0, 0x00, 0xa4, 0x00, 0x00)) {
                        revert(0x00, 0x00)
                    }
                }

                case 1 {
                    let cb_key := xor(GUARD_KEY, pool)
                    tstore(cb_key, 1)

                    let v3_zfo  := xor(zfc, and(flags, 0x01))
                    let sqrtLim := MAX_SQRT_RATIO
                    if v3_zfo { sqrtLim := MIN_SQRT_RATIO }

                    mstore(0x00, shl(224, V3_SWAP))
                    mstore(0x04, address())
                    mstore(0x24, v3_zfo)
                    mstore(0x44, unmatched_in)
                    mstore(0x64, sqrtLim)
                    mstore(0x84, 0xa0)
                    mstore(0xa4, 0x20)
                    mstore(0xc4, tokenIn)

                    if iszero(call(gas(), pool, 0, 0x00, 0xe4, 0x80, 0x40)) {
                        revert(0x00, 0x00)
                    }
                    tstore(cb_key, 0)

                    let a0 := mload(0x80)
                    let a1 := mload(0xa0)
                    switch v3_zfo
                    case 1 {
                        if slt(a1, 0) { amm_out := sub(0, a1) }
                    }
                    default {
                        if slt(a0, 0) { amm_out := sub(0, a0) }
                    }
                }

                case 2 {
                    mstore(0x00, shl(224, ERC20_APPROVE))
                    mstore(0x04, pool)
                    mstore(0x24, unmatched_in)
                    pop(call(gas(), tokenIn, 0, 0x00, 0x44, 0x00, 0x00))

                    let ci := and(shr(1, flags), 0x07)
                    let cj := and(shr(4, flags), 0x07)
                    if iszero(zfc) {
                        let tmp := ci
                        ci := cj
                        cj := tmp
                    }

                    mstore(0x00, shl(224, ERC20_BALANCE_OF))
                    mstore(0x04, address())
                    staticcall(5000, tokenOut, 0x00, 0x24, 0x80, 0x20)
                    let bal_before := mload(0x80)

                    mstore(0x00, shl(224, CRV_EXCHANGE_REF))
                    mstore(0x04, ci)
                    mstore(0x24, cj)
                    mstore(0x44, unmatched_in)
                    mstore(0x64, 0x00)
                    mstore(0x84, REFERRAL)
                    let crv_ok := call(gas(), pool, 0, 0x00, 0xa4, 0x00, 0x00)

                    if iszero(crv_ok) {
                        mstore(0x00, shl(224, CRV_EXCHANGE))
                        mstore(0x04, ci)
                        mstore(0x24, cj)
                        mstore(0x44, unmatched_in)
                        mstore(0x64, 0x00)
                        if iszero(call(gas(), pool, 0, 0x00, 0x84, 0x00, 0x00)) {
                            revert(0x00, 0x00)
                        }
                    }

                    mstore(0x00, shl(224, ERC20_BALANCE_OF))
                    mstore(0x04, address())
                    staticcall(5000, tokenOut, 0x00, 0x24, 0x80, 0x20)
                    amm_out := sub(mload(0x80), bal_before)

                    mstore(0x00, shl(224, ERC20_APPROVE))
                    mstore(0x04, pool)
                    mstore(0x24, 0x00)
                    pop(call(gas(), tokenIn, 0, 0x00, 0x44, 0x00, 0x00))
                }

                default { revert(0x00, 0x00) }
            }

            let total_out := add(match_out, amm_out)
            let proto_fee := div(total_out, 1000)
            amountOut     := sub(total_out, proto_fee)

            if lt(amountOut, minOut) {
                mstore(0x00, shl(224, ERR_SLIPPAGE))
                mstore(0x04, minOut)
                mstore(0x24, amountOut)
                mstore(0x44, address())
                mstore(0x64, cfg_slot)
                mstore(0x84, skey)
                revert(0x00, 0xa4)
            }

            mstore(0x00, shl(224, ERC20_TRANSFER))
            mstore(0x04, recipient)
            mstore(0x24, amountOut)
            {
                let ok := call(gas(), tokenOut, 0, 0x00, 0x44, 0x80, 0x20)
                if iszero(ok) { revert(0x00, 0x00) }
                if returndatasize() {
                    if iszero(mload(0x80)) { revert(0x00, 0x00) }
                }
            }

            let flow_delta := 0
            switch zfc
            case 1 { flow_delta := match_in }
            default { flow_delta := sub(0, match_out) }
            let new_net   := add(net_flow, flow_delta)
            let new_state := or(
                shl(128, and(new_net, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
                clrP
            )
            tstore(pkey, new_state)
            if match_out { sstore(skey, new_state) }

            mstore(0x80,  tokenIn)
            mstore(0xa0,  tokenOut)
            mstore(0xc0,  or(
                shl(128, and(amountIn, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
                and(match_in, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            ))
            mstore(0xe0,  or(
                shl(128, and(amm_out, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
                and(amountOut, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            ))
            mstore(0x100, or(
                shl(128, and(clrP, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
                and(fee_bps, 0xFFFF)
            ))
            mstore(0x120, pool)
            log3(0x80, 0xc0, SWAP_TOPIC, pkey, gt(match_out, 0))

            tstore(GUARD_KEY, 0)
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        assembly {
            if iszero(tload(xor(GUARD_KEY, caller()))) {
                mstore(0x00, shl(224, ERR_UNAUTHORIZED))
                revert(0x00, 0x04)
            }

            let tokenIn := calldataload(data.offset)

            let owed := 0
            if sgt(amount0Delta, 0) { owed := amount0Delta }
            if sgt(amount1Delta, 0) { owed := amount1Delta }

            if gt(owed, 0) {
                mstore(0x00, shl(224, ERC20_TRANSFER))
                mstore(0x04, caller())
                mstore(0x24, owed)
                let ok := call(gas(), tokenIn, 0, 0x00, 0x44, 0x80, 0x20)
                if iszero(ok) { revert(0x00, 0x00) }
                if returndatasize() {
                    if iszero(mload(0x80)) { revert(0x00, 0x00) }
                }
            }
        }
    }

    function registerPair(
        address tokenA,
        address tokenB,
        address pool,
        uint8   interfaceType,
        uint16  feeBps
    ) external {
        assembly {
            if iszero(eq(caller(), OWNER)) {
                mstore(0x00, shl(224, ERR_UNAUTHORIZED))
                revert(0x00, 0x04)
            }

            let t0 := tokenA
            let t1 := tokenB
            if gt(tokenA, tokenB) {
                t0 := tokenB
                t1 := tokenA
            }
            mstore(0x00, t0)
            mstore(0x20, t1)
            let pkey := keccak256(0x00, 0x40)

            let inv := 0
            if iszero(interfaceType) {
                mstore(0x00, shl(224, V2_TOKEN0))
                let ok := staticcall(5000, pool, 0x00, 0x04, 0x80, 0x20)
                if ok {
                    let tok0 := and(mload(0x80), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    if iszero(eq(tok0, t0)) { inv := 1 }
                }
            }

            let flags_val := inv
            let cfg := or(
                or(
                    or(
                        or(
                            and(pool, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF),
                            shl(160, and(interfaceType, 0xFF))
                        ),
                        shl(168, and(feeBps, 0xFFFF))
                    ),
                    shl(184, and(flags_val, 0xFF))
                ),
                0x00
            )

            mstore(0x00, pkey)
            mstore(0x20, 0x00)
            sstore(keccak256(0x00, 0x40), cfg)

            mstore(0x20, 0x01)
            sstore(keccak256(0x00, 0x40), 0x00)

            tstore(pkey, 0x00)
        }
    }

    function setCurveIndices(
        address tokenA,
        address tokenB,
        uint8   coinI,
        uint8   coinJ
    ) external {
        assembly {
            if iszero(eq(caller(), OWNER)) {
                mstore(0x00, shl(224, ERR_UNAUTHORIZED))
                revert(0x00, 0x04)
            }
            let t0 := tokenA
            let t1 := tokenB
            if gt(tokenA, tokenB) {
                t0 := tokenB
                t1 := tokenA
            }
            mstore(0x00, t0)
            mstore(0x20, t1)
            let pkey := keccak256(0x00, 0x40)
            mstore(0x00, pkey)
            mstore(0x20, 0x00)
            let cslot := keccak256(0x00, 0x40)
            let cfg   := sload(cslot)

            let old_flags := and(shr(184, cfg), 0xFF)
            let inv_bit   := and(old_flags, 0x01)
            let new_flags := or(
                inv_bit,
                or(
                    shl(1, and(coinI, 0x07)),
                    shl(4, and(coinJ, 0x07))
                )
            )
            cfg := or(
                and(cfg, not(shl(184, 0xFF))),
                shl(184, and(new_flags, 0xFF))
            )
            sstore(cslot, cfg)
        }
    }

    function setAdverseSelection(
        address tokenA,
        address tokenB,
        uint16  advSelBps
    ) external {
        assembly {
            if iszero(eq(caller(), OWNER)) {
                mstore(0x00, shl(224, ERR_UNAUTHORIZED))
                revert(0x00, 0x04)
            }
            let t0 := tokenA
            let t1 := tokenB
            if gt(tokenA, tokenB) {
                t0 := tokenB
                t1 := tokenA
            }
            mstore(0x00, t0)
            mstore(0x20, t1)
            let pkey := keccak256(0x00, 0x40)
            mstore(0x00, pkey)
            mstore(0x20, 0x00)
            let cslot := keccak256(0x00, 0x40)
            let cfg   := sload(cslot)
            cfg := or(
                and(cfg, not(shl(192, 0xFFFF))),
                shl(192, and(advSelBps, 0xFFFF))
            )
            sstore(cslot, cfg)
        }
    }

    function withdrawFees(address token, address to) external {
        assembly {
            if iszero(eq(caller(), OWNER)) {
                mstore(0x00, shl(224, ERR_UNAUTHORIZED))
                revert(0x00, 0x04)
            }
            mstore(0x00, shl(224, ERC20_BALANCE_OF))
            mstore(0x04, address())
            pop(staticcall(gas(), token, 0x00, 0x24, 0x80, 0x20))
            let bal := mload(0x80)
            if gt(bal, 0x00) {
                mstore(0x00, shl(224, ERC20_TRANSFER))
                mstore(0x04, to)
                mstore(0x24, bal)
                if iszero(call(gas(), token, 0, 0x00, 0x44, 0x00, 0x00)) {
                    revert(0x00, 0x00)
                }
            }
        }
    }

    function multicall(
        bytes[] calldata calls
    ) external returns (bytes[] memory results) {
        uint256 n = calls.length;
        results = new bytes[](n);
        for (uint256 i; i < n; ) {
            bytes calldata c = calls[i];
            (bool ok, bytes memory res) = address(this).delegatecall(c);
            if (!ok) {
                assembly { revert(add(res, 0x20), mload(res)) }
            }
            results[i] = res;
            unchecked { ++i; }
        }
    }
}
