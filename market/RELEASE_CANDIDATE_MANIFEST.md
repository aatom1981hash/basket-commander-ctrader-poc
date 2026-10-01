# Basket Commander PRO Release Candidate Manifest

Release candidate date: 2026-10-01

## MT5 PRO v1.00
- Source: market/mt5/Basket_Commander_PRO_MT5_v1.00.mq5
- Binary: market/mt5/Basket_Commander_PRO_MT5_v1.00.ex5
- Compile result: 0 errors, 0 warnings
- Integration test: 20 PASS / 0 FAIL
- Test environment: STARTRADER Financial Demo, EURUSD M1, hedging tester
- Source SHA256: 7CD36F37085EB3C649116BF379EC1B4905F5C297B86030F592B05BFC6C9C9688
- Binary SHA256: F9CD369508F02B91A73A0AF96F545ACECC8C4367C015BD4BA0D1D7A311BF44DE

## MT4 PRO v1.00
- Source: market/mt4/Basket_Commander_PRO_MT4_v1.00.mq4
- Binary: market/mt4/Basket_Commander_PRO_MT4_v1.00.ex4
- Compile result: 0 errors, 0 warnings
- Live-demo integration test: 16 PASS / 0 FAIL
- Test account: STARTRADERFinancial-Demo 2100678076, EURUSD
- Source SHA256: 64D2F3E56BDDCB8CC4805A3A1F1887555614CAE6F515D11E591F08162E6B26A0
- Binary SHA256: 0EFF885A19E1F274CD56E384BCE2865351570A535B5823D45AB51D6B47F24056

## Production compliance scan
Both PRO source files scanned clean for:
- DLL imports: 0
- #import blocks: 0
- WebRequest: 0
- Telegram/remote-controller code: 0
- external URLs: 0
- account-number locks: 0
- integration-test harness code in production source: 0

## Commercial settings
- Product: Basket Commander PRO MT5 / MT4
- Launch price: USD 59
- 1-month rental: USD 30
- Activations: 5
- Planned later price: USD 79 after stable adoption/reviews

## Safety/state behavior
- Normal terminal/VPS restart preserves management settings.
- Manual EA removal clears basket targets/protection state before a later re-attach.
- A state-schema guard clears legacy persisted basket targets once when upgrading to this release candidate.
- Stats panel can be collapsed/expanded and its UI preference persists separately.

## Remaining release gates
- Visual UI review and final Market screenshots
- Final English manual/product listing consistency check
- MQL5 automatic Market validation
- Final upload/submission
