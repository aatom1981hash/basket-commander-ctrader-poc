# Basket Commander PRO — Release Validation

Validation date: 2026-10-01

## MT5 PRO v1.00

Source:
- market/mt5/Basket_Commander_PRO_MT5_v1.00.mq5

Build:
- MetaEditor / MT5 x64
- Compile result: 0 errors, 0 warnings

Market-compliance source scan:
- #import: 0
- DLL references: 0
- WebRequest: 0
- Telegram / remote bridge: 0
- External URLs: 0
- Account-number locks: 0
- Integration-test code in production source: 0

Automated Strategy Tester integration:
- Test harness: tests/mt5/Basket_Commander_PRO_MT5_IntegrationTest.mq5
- Broker environment: STARTRADERFinancial-Demo
- Emulated login: 1610115557
- Symbol/timeframe: EURUSD M1
- Test date: 2026-09-29
- Initial deposit: USD 10,000
- Leverage: 1:500
- History quality: 100%
- Result: PASS 20 / FAIL 0

Validated behaviors include:
- Hedging account initialization
- BUY + SELL positions
- CLOSE 50% lot reduction
- Pending-order detection and deletion
- CLOSE BASKET
- Basket TP/SL trigger path
- Basket Breakeven trigger path
- Profit trailing trigger path
- BUY scope close
- SELL scope preservation / close
- Account-wide positions + pending-order close

After testing, the original Basket Commander v1.25 MT5 terminal was restored on demo account 1610115557 and verified connected, trading-enabled and flat.

## MT4 PRO v1.00

Source:
- market/mt4/Basket_Commander_PRO_MT4_v1.00.mq4

Build:
- MetaEditor / MT4 build 1481
- Compile result: 0 errors, 0 warnings

Market-compliance source scan:
- #import: 0
- DLL references: 0
- WebRequest: 0
- Telegram / remote bridge: 0
- External URLs: 0
- Account-number locks: 0
- Integration-test code in production source: 0

Automated live-demo integration:
- Test harness: tests/mt4/Basket_Commander_PRO_MT4_IntegrationTest.mq4
- Demo account: 2100678076
- Server: STARTRADERFinancial-Demo
- Symbol: EURUSD
- Result: PASS 16 / FAIL 0

Validated behaviors include:
- BUY + SELL opening
- CLOSE 50% with broker lot-step handling
- Pending-order creation and deletion
- CLOSE BASKET
- Basket TP/SL trigger path
- Basket Breakeven trigger path
- Profit trailing trigger path
- Account-wide positions + pending-order close
- Persistent basket setting save/load

Additional MT4 parity fixes completed after the first port:
- Editable persistent Account Equity TP/SL
- Account/server-specific equity state
- Adopted-basket cycle start from earliest still-open trade
- CLOSE 50% remains current-symbol scoped, matching MT5 behavior

## Remaining release gates

- Final production-binary checksum/archive
- Visual panel review at common display scaling
- Screenshot set for each platform
- Final English listing copy review
- MQL5 automatic Market validation
- Seller-side product submission
- Post-submission fixes if MetaQuotes validator reports platform-specific edge cases
