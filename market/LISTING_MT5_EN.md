# Basket Commander Pro MT5

## Product positioning
Basket Commander Pro MT5 is a trade-management Expert Advisor for MetaTrader 5. It does not generate entry signals and it does not open trades as a strategy. It manages existing positions, baskets and account-equity exit rules from a single on-chart panel.

## Suggested Market settings
- Program type: Expert Advisor
- Use case: Trade management / position management
- Purchase price: USD 59
- One-month rental: USD 30
- Activations: 5
- Public version: 1.00

## Short description
Basket, position and account-equity management panel for MetaTrader 5.

## Description

Basket Commander Pro MT5 is designed for traders who manage several open positions as one basket.

The Expert Advisor provides manual and automatic exit controls while leaving trade entry decisions to the trader or to another trading system. It can manage the current chart symbol, filter positions by Magic Number, separate BUY and SELL baskets on hedging accounts, and apply account-wide equity limits.

The product does not contain an entry strategy or signal generator.

### Basket management

Basket Commander can calculate the total cycle result of the selected basket using floating profit or loss together with realized results from partial closes belonging to the same basket cycle.

Available basket controls include:

- Basket TP in account currency
- Basket SL in account currency
- Positive protected-profit floor
- Basket Breakeven
- Profit trailing with trigger and distance
- CLOSE 50%
- CLOSE 50% + BE
- CLOSE BASKET

Basket thresholds remain attached to the basket cycle when a partial close is performed.

### Position scope

The panel supports:

- BOTH scope
- BUY scope
- SELL scope
- Combined mode
- Split BUY and SELL mode on hedging accounts
- Magic Number filtering
- Manual trades with Magic Number 0
- All Magic Numbers with Magic Number -1

For MT5 netting accounts, combined mode should be used without Magic Number filtering.

### Symbol basket and whole basket

The manual CLOSE BASKET command can operate in two modes:

MANAGE SYMBOL BASKET closes matching positions and pending orders for the current chart symbol.

MANAGE WHOLE BASKET closes matching positions across all symbols while still respecting the selected Magic Number and BUY or SELL scope.

CLOSE 50% remains a current-symbol operation.

### Account Equity TP and SL

Account Equity TP and Account Equity SL use absolute account-currency equity levels.

When an equity limit is reached, Basket Commander attempts to cancel pending orders and close open positions across the account. The close state is persisted and retried until the account is flat when trading is available.

Account equity settings are stored separately for each trading account and server.

### Profit trailing

Profit trailing uses two values:

Trail Trigger: basket profit at which trailing becomes active.

Trail Distance: allowed distance below the highest recorded basket result after trailing is armed.

Example:

Trail Trigger = 200
Trail Distance = 100

After the basket reaches the trigger, Basket Commander records the highest basket result. If the total basket result later falls 100 account-currency units below the recorded peak, the basket exit is triggered.

### Breakeven

Basket Breakeven has two operating states.

Recovery mode is used when the basket result is below zero. The basket is closed if its total cycle result recovers to breakeven.

Protect mode is used when the basket result is above zero. It protects the breakeven level if the result falls back to zero.

CLOSE 50% + BE first attempts to reduce each eligible current-symbol position by half and then enables the appropriate breakeven mode for the remaining basket.

### Partial-close handling

CLOSE 50%:

- snapshots eligible positions before sending requests;
- calculates a legal half-volume using the symbol minimum volume and lot step;
- never deliberately converts a half-close into a full close;
- skips positions that cannot be safely halved;
- keeps basket monetary thresholds active after the reduction.

### Pending orders

When CLOSE BASKET or an account-equity exit is executed, matching pending entry orders are also removed according to the selected scope.

### Persistent settings

Basket Commander stores relevant management state so that settings can survive normal terminal restarts.

Persistent state includes basket thresholds, trailing state, basket mode, selected management scope and account-equity settings.

Settings are not intentionally transferred to a different trading account.

### Chart display

The Basket Commander panel remains in front of the chart.

MetaTrader trade-history objects remain visible on the chart but are moved behind the panel while the Expert Advisor is attached. Their original layer state is restored when the Expert Advisor is removed.

## Quick Start

1. Install Basket Commander Pro MT5 from the MetaTrader Market.
2. Open the chart of the symbol you want to manage.
3. Attach Basket Commander Pro MT5 to the chart.
4. Enable algorithmic trading for the Expert Advisor.
5. Set Magic Number:
   - -1 for all Magic Numbers
   - 0 for manual positions
   - another value for positions using that Magic Number
6. Choose Combined or Split mode.
7. Enter Basket TP, Basket SL and optional trailing values.
8. Select MANAGE SYMBOL BASKET or MANAGE WHOLE BASKET for the manual CLOSE BASKET command.
9. If required, enter Account Equity TP and SL as absolute equity levels.
10. Verify the panel status before using manual close controls.

## Important operating notes

Run only one Basket Commander instance for an overlapping symbol and Magic Number basket.

Split BUY and SELL mode requires an MT5 hedging account.

On netting accounts, use combined mode and Magic Number -1.

Account Equity TP and SL apply to the whole trading account, not only the current symbol or selected Magic Number.

A value of 0 disables the corresponding monetary limit.

Execution depends on broker trading permissions, market availability, symbol trading conditions, connection quality and available liquidity.

## Risk notice

Basket Commander Pro MT5 is a trade-management tool. It does not guarantee trading results and does not remove market, execution or operational risk.

Closing and partial-closing requests may be delayed, rejected or filled differently from the requested price because of market conditions, broker rules, connection conditions or other execution factors.

Account Equity TP and SL can close positions and pending orders across the entire account. Confirm the entered levels before enabling these functions.

Test the product on a demo account and confirm that its scope, Magic Number settings and exit behavior match your intended workflow before using it on a live account.

## FAQ

### Does Basket Commander open trades?
No. It manages existing positions and exit conditions.

### Does it provide trading signals?
No.

### Can it manage manual trades?
Yes. Use Magic Number 0.

### Can it manage all Magic Numbers?
Yes. Use Magic Number -1.

### Can BUY and SELL positions be managed separately?
Yes, on MT5 hedging accounts using Split mode.

### Does CLOSE 50% close exactly half?
It attempts to close a legal volume no greater than half of each eligible position. The result is adjusted to the symbol lot step and minimum volume. Positions that cannot be safely halved are skipped.

### Does a partial close reset Basket TP or SL?
No. Basket monetary thresholds remain active for the basket cycle.

### What does MANAGE WHOLE BASKET change?
It changes the scope of the manual CLOSE BASKET command from the current symbol to matching positions and pending orders across all symbols.

### Does MANAGE WHOLE BASKET affect CLOSE 50%?
No. CLOSE 50% remains current-symbol only.

### Are Account Equity TP and SL filtered by Magic Number?
No. Account equity limits apply to the whole trading account.

### Are pending orders handled?
Yes. Matching pending entry orders are deleted during basket close operations according to scope. Account-equity exits attempt to remove account pending orders before closing positions.

### Will settings survive a terminal restart?
The Expert Advisor persists relevant management settings and state. Broker execution state and market availability remain external to the product.

### Does it work on netting accounts?
Combined basket management can be used. Split BUY and SELL mode and Magic Number filtering are intended for hedging accounts.

## Version history

### Version 1.00
Initial Market release.

- Basket TP and Basket SL
- Protected-profit Basket SL
- Basket Breakeven
- Profit trailing
- CLOSE 50%
- CLOSE 50% + BE
- Combined and Split basket modes
- BUY, SELL and BOTH scopes
- Magic Number filter
- Symbol basket and whole-basket manual close scopes
- Pending-order handling
- Account Equity TP and SL
- Persistent management state
- Trade-history chart-layer handling
