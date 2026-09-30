# Basket Commander Commercial Product Matrix

## Decision
For MQL5 Market, publish one full-featured product per platform:
- Basket Commander PRO MT5
- Basket Commander PRO MT4

Do not publish a separate restricted Demo/Lite/Simple edition on MQL5 Market.
The Core/Simple source branches are retained for future channels, bundles, OEM/custom builds, or a genuinely differentiated product.

## Why
MQL5 Market rules prohibit:
- separate functionally restricted demo/light products;
- multiple highly similar products based on the same idea;
- third-party licensing, sales or update-control systems;
- DLL dependencies in Market products.

Use the built-in Market demo plus one-month rental instead.

## Launch pricing
### Basket Commander PRO MT5
- Launch purchase price: USD 59
- Activations: 5
- One-month rental: USD 30
- Target post-launch price: USD 79 after stable reviews/support history

### Basket Commander PRO MT4
- Launch purchase price: USD 59
- Activations: 5
- One-month rental: USD 30
- Target post-launch price: USD 79 after stable reviews/support history

## PRO feature set
- CLOSE 50%
- CLOSE 50% + BE
- Basket Breakeven
- Basket TP / Basket SL
- Profit trailing trigger + distance
- Account Equity TP / SL
- BUY / SELL / BOTH scope
- Combined / Split
- Magic Number filter
- MANAGE SYMBOL BASKET
- MANAGE WHOLE BASKET
- Current-symbol and whole-basket close
- Pending order handling
- Persistent settings
- Trade-history lines remain visible while the panel stays opaque
- Existing-position management only; no signal generation or entry strategy

## Core/Simple branch
Candidate feature set:
- Basket TP / Basket SL
- CLOSE 50%
- CLOSE BASKET
- Magic Number filter
- MANAGE SYMBOL BASKET
- MANAGE WHOLE BASKET
- Pending order handling
- Persistent settings

The Core branch is not an MQL5 Market launch SKU unless it is later differentiated enough to comply with Market anti-duplication rules.

## Build status
- MT5 PRO v1.00: Market-clean source created; Telegram/remote subsystem removed.
- MT5 Core v1.00: candidate source created.
- MT4 PRO v1.00: native MT4 port candidate created.
- MT4 Core v1.00: candidate source created.

## Release gates
1. Compile with zero errors and zero warnings.
2. Run MT5 Strategy Tester / Market-validation-oriented tests.
3. Test hedging and netting behavior on MT5.
4. Test MT4 order handling, partial-close lot rounding, pending deletion and history accounting.
5. Test disconnect/trade-disabled states.
6. Test state persistence after timeframe/terminal/VPS restart.
7. Produce English screenshots and final manual.
8. Submit compiled EX5/EX4 only to MQL5 Market.
