using System;
using System.Globalization;
using System.Linq;
using cAlgo.API;

namespace cAlgo.Plugins
{
    [Plugin(AccessRights = AccessRights.None)]
    public class BasketCommanderNativePoc : Plugin
    {
        private StackPanel? _root;
        private StackPanel? _basketPanel;
        private TextBlock? _accountText;
        private TextBlock? _scopeText;
        private TextBlock? _managedText;
        private TextBlock? _trailText;
        private TextBlock? _targetsText;
        private TextBlock? _statusText;
        private StackPanel? _proHost;
        private StackPanel? _proPanel;
        private TextBox? _tpBox;
        private TextBox? _slBox;
        private TextBox? _tpPctBox;
        private TextBox? _slPctBox;
        private TextBox? _trailTriggerBox;
        private TextBox? _trailDistanceBox;
        private CheckBox? _pendingCheck;

        private bool _manageWhole = true;
        private bool _proMode = true;
        private string _managedSymbol = "";
        private bool _includePending;
        private double _tpCcy;
        private double _slCcy;
        private double _tpPct;
        private double _slPct;
        private double _trailTrigger;
        private double _trailDistance;
        private bool _trailArmed;
        private double _trailPeak;
        private string _trailSignature = "";
        private DateTime _lastTrailPersistUtc = DateTime.MinValue;
        private DateTime _autoCooldownUntilUtc = DateTime.MinValue;
        private const int AutoCooldownSeconds = 5;

        protected override void OnStart()
        {
            LoadSettings();
            var tab = TradeWatch.AddTab("Basket Commander Native");
            _root = new StackPanel { Orientation = Orientation.Vertical, Margin = 10 };
            var scroll = new ScrollViewer
            {
                Content = _root,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto
            };
            tab.Child = scroll;
            BuildStaticUi();
            Timer.Start(TimeSpan.FromSeconds(1));
            RefreshUi();
        }

        protected override void OnTimer()
        {
            EvaluateAutomation();
            RefreshUi();
        }

        protected override void OnStop()
        {
            SaveSettings();
            SaveTrailState(true);
        }

        private void BuildStaticUi()
        {
            if (_root == null)
                return;

            _root.AddChild(new TextBlock { Text = "Basket Commander Native v0.5", FontSize = 16, Margin = 5 });
            _accountText = new TextBlock { FontSize = 14, Margin = 5 };
            _scopeText = new TextBlock { FontSize = 13, Margin = 5 };
            _managedText = new TextBlock { Margin = 5 };
            _trailText = new TextBlock { Margin = 5 };
            _targetsText = new TextBlock { Margin = 5 };
            _statusText = new TextBlock { Margin = 5 };
            _root.AddChild(_accountText);
            _root.AddChild(_scopeText);
            _root.AddChild(_managedText);
            _root.AddChild(_trailText);
            _root.AddChild(_targetsText);
            _root.AddChild(_statusText);

            var viewRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            var simpleButton = new Button { Text = "SIMPLE", Width = 95, Margin = 3 };
            simpleButton.Click += _ => SetProMode(false);
            var proButton = new Button { Text = "PRO", Width = 95, Margin = 3 };
            proButton.Click += _ => SetProMode(true);
            viewRow.AddChild(simpleButton);
            viewRow.AddChild(proButton);
            _root.AddChild(viewRow);

            var modeRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            var symbolModeButton = new Button { Text = "MANAGE SYMBOL BASKET", Width = 190, Margin = 3 };
            symbolModeButton.Click += _ => SetSymbolModeFromButton();
            var wholeButton = new Button { Text = "MANAGE WHOLE BASKET", Width = 190, Margin = 3 };
            wholeButton.Click += _ => SetWholeMode();
            modeRow.AddChild(symbolModeButton);
            modeRow.AddChild(wholeButton);
            _root.AddChild(modeRow);

            _proHost = new StackPanel { Orientation = Orientation.Vertical, Margin = 0 };
            _proPanel = new StackPanel { Orientation = Orientation.Vertical, Margin = 0 };
            _root.AddChild(_proHost);

            var settingsRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            _tpBox = MakeBox(_tpCcy);
            _slBox = MakeBox(_slCcy);
            _trailTriggerBox = MakeBox(_trailTrigger);
            _trailDistanceBox = MakeBox(_trailDistance);
            AddLabeled(settingsRow, "TP CCY", _tpBox);
            AddLabeled(settingsRow, "SL CCY", _slBox);
            AddLabeled(settingsRow, "Trail trigger", _trailTriggerBox);
            AddLabeled(settingsRow, "Trail distance", _trailDistanceBox);
            _proPanel.AddChild(settingsRow);

            var percentRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            _tpPctBox = MakeBox(_tpPct);
            _slPctBox = MakeBox(_slPct);
            AddLabeled(percentRow, "TP % balance", _tpPctBox);
            AddLabeled(percentRow, "SL % balance", _slPctBox);
            _proPanel.AddChild(percentRow);

            var settingsActions = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            var applyButton = new Button { Text = "APPLY SETTINGS", Width = 150, Margin = 3 };
            applyButton.Click += _ => ApplySettings();
            _pendingCheck = new CheckBox { Text = "Include pending orders", IsChecked = _includePending, Margin = 5 };
            _pendingCheck.Click += args =>
            {
                _includePending = args.CheckBox.IsChecked == true;
                SaveSettings();
            };
            var resetButton = new Button { Text = "RESET MANAGEMENT", Width = 155, Margin = 3 };
            resetButton.Click += _ => ResetManagementSettings();
            settingsActions.AddChild(applyButton);
            settingsActions.AddChild(resetButton);
            settingsActions.AddChild(_pendingCheck);
            _proPanel.AddChild(settingsActions);

            var actionRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            var closeManaged = new Button { Text = "CLOSE MANAGED", Width = 135, Margin = 3 };
            closeManaged.Click += _ => CloseManagedManual();
            var closeHalf = new Button { Text = "CLOSE 50%", Width = 115, Margin = 3 };
            closeHalf.Click += _ => CloseHalfManaged(false);
            var closeHalfBe = new Button { Text = "CLOSE 50% + BE", Width = 145, Margin = 3 };
            closeHalfBe.Click += _ => CloseHalfManaged(true);
            var beButton = new Button { Text = "BREAK EVEN", Width = 120, Margin = 3 };
            beButton.Click += _ => ApplyBreakEven(true);
            actionRow.AddChild(closeManaged);
            actionRow.AddChild(closeHalf);
            actionRow.AddChild(closeHalfBe);
            actionRow.AddChild(beButton);
            _root.AddChild(actionRow);

            var emergencyRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            var closeWhole = new Button { Text = "CLOSE WHOLE BASKET", Width = 180, Margin = 3 };
            closeWhole.Click += _ => CloseWholeBasket();
            emergencyRow.AddChild(closeWhole);
            _root.AddChild(emergencyRow);
            UpdateProPanelVisibility();
        }

        private TextBox MakeBox(double value)
        {
            return new TextBox
            {
                Text = value.ToString("0.##", CultureInfo.InvariantCulture),
                Width = 85,
                Margin = 3
            };
        }

        private void AddLabeled(StackPanel row, string label, TextBox box)
        {
            row.AddChild(new TextBlock { Text = label, Margin = 5 });
            row.AddChild(box);
        }

        private string TargetState(double value)
        {
            return value > 0 ? $"ON {value:0.##}" : "OFF";
        }

        private void SetProMode(bool proMode)
        {
            _proMode = proMode;
            SaveSettings();
            UpdateProPanelVisibility();
            SetStatus(proMode ? "PRO view enabled." : "SIMPLE view enabled.");
            RefreshUi();
        }

        private void UpdateProPanelVisibility()
        {
            if (_proHost == null || _proPanel == null)
                return;

            var shown = _proHost.HasChild(_proPanel);
            if (_proMode && !shown)
                _proHost.AddChild(_proPanel);
            else if (!_proMode && shown)
                _proHost.RemoveChild(_proPanel);
        }

        private void ResetManagementSettings()
        {
            var result = MessageBox.Show(
                "Reset all Basket Commander management settings?\nThis does not close or modify any trades.",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            _manageWhole = true;
            _managedSymbol = "";
            _includePending = false;
            _tpCcy = 0;
            _slCcy = 0;
            _tpPct = 0;
            _slPct = 0;
            _trailTrigger = 0;
            _trailDistance = 0;
            _autoCooldownUntilUtc = DateTime.MinValue;
            ResetTrail();
            SyncSettingControls();
            SaveSettings();
            SetStatus("Management settings reset. No trades were changed.");
            RefreshUi();
        }

        private void SyncSettingControls()
        {
            if (_tpBox != null) _tpBox.Text = _tpCcy.ToString("0.##", CultureInfo.InvariantCulture);
            if (_slBox != null) _slBox.Text = _slCcy.ToString("0.##", CultureInfo.InvariantCulture);
            if (_tpPctBox != null) _tpPctBox.Text = _tpPct.ToString("0.##", CultureInfo.InvariantCulture);
            if (_slPctBox != null) _slPctBox.Text = _slPct.ToString("0.##", CultureInfo.InvariantCulture);
            if (_trailTriggerBox != null) _trailTriggerBox.Text = _trailTrigger.ToString("0.##", CultureInfo.InvariantCulture);
            if (_trailDistanceBox != null) _trailDistanceBox.Text = _trailDistance.ToString("0.##", CultureInfo.InvariantCulture);
            if (_pendingCheck != null) _pendingCheck.IsChecked = _includePending;
        }

        private void RefreshUi()
        {
            if (_root == null || _accountText == null || _scopeText == null ||
                _managedText == null || _trailText == null || _targetsText == null)
                return;

            _accountText.Text =
                $"Balance {Account.Balance:F2} {Account.Asset.Name}   Equity {Account.Equity:F2}   Margin {Account.Margin:F2}";

            var managed = GetManagedPositions();
            var pnl = managed.Sum(p => p.NetProfit);
            var lots = managed.Sum(p => p.Quantity);
            var pendingCount = GetManagedPendingOrders().Length;
            var pnlPct = Account.Balance > 0 ? pnl / Account.Balance * 100.0 : 0;
            _scopeText.Text = _manageWhole
                ? "MODE: WHOLE ACCOUNT"
                : $"MODE: SYMBOL — {_managedSymbol}";
            _managedText.Text =
                $"Managed: {managed.Length} positions · {lots:F2} lots · P/L {pnl:F2} ({pnlPct:F2}%) · Pending {pendingCount}";
            _trailText.Text = _trailArmed
                ? $"Trailing ARMED · peak {_trailPeak:F2} · close at {_trailPeak - _trailDistance:F2}"
                : "Trailing not armed";

            var cooldownLeft = Math.Max(0, (_autoCooldownUntilUtc - DateTime.UtcNow).TotalSeconds);
            var cooldownText = cooldownLeft > 0 ? $" · AUTO COOLDOWN {Math.Ceiling(cooldownLeft):0}s" : "";
            _targetsText.Text =
                $"Targets: TP CCY {TargetState(_tpCcy)} · SL CCY {TargetState(_slCcy)} · " +
                $"TP % {TargetState(_tpPct)} · SL % {TargetState(_slPct)} · " +
                $"Trail {((_trailTrigger > 0 && _trailDistance > 0) ? $"ON {_trailTrigger:0.##}/{_trailDistance:0.##}" : "OFF")} · " +
                $"Pending {(_includePending ? "ON" : "OFF")} · View {(_proMode ? "PRO" : "SIMPLE")}{cooldownText}";

            if (_basketPanel != null && _root.HasChild(_basketPanel))
                _root.RemoveChild(_basketPanel);

            _basketPanel = new StackPanel { Orientation = Orientation.Vertical };
            var groups = Positions
                .GroupBy(p => new { p.SymbolName, p.TradeType })
                .OrderBy(g => g.Key.SymbolName)
                .ThenBy(g => g.Key.TradeType)
                .ToArray();

            if (groups.Length == 0)
                _basketPanel.AddChild(new TextBlock { Text = "No open positions", Margin = 5 });

            foreach (var group in groups)
            {
                var symbol = group.Key.SymbolName;
                var side = group.Key.TradeType;
                var totalVolume = group.Sum(p => p.VolumeInUnits);
                var avgEntry = totalVolume > 0
                    ? group.Sum(p => p.EntryPrice * p.VolumeInUnits) / totalVolume
                    : 0;
                var net = group.Sum(p => p.NetProfit);
                var swap = group.Sum(p => p.Swap);
                var commission = group.Sum(p => p.Commissions);
                var avgText = avgEntry.ToString($"F{group.First().Symbol.Digits}", CultureInfo.InvariantCulture);
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
                row.AddChild(new TextBlock
                {
                    Text = $"{symbol} {side} | {group.Count()} pos | {group.Sum(p => p.Quantity):F2} lots | " +
                           $"Avg {avgText} | Net {net:F2} | Swap {swap:F2} | Comm {commission:F2}",
                    Width = 650,
                    Margin = 5
                });

                var manageButton = new Button { Text = "MANAGE SYMBOL", Width = 130, Margin = 3 };
                manageButton.Click += _ => SetSymbolMode(symbol);
                var closeButton = new Button { Text = "CLOSE BASKET", Width = 125, Margin = 3 };
                closeButton.Click += _ => CloseBasket(symbol, side);
                row.AddChild(manageButton);
                row.AddChild(closeButton);
                _basketPanel.AddChild(row);
            }

            _root.AddChild(_basketPanel);
        }

        private Position[] GetManagedPositions()
        {
            return _manageWhole
                ? Positions.ToArray()
                : Positions.Where(p => p.SymbolName == _managedSymbol).ToArray();
        }

        private PendingOrder[] GetManagedPendingOrders()
        {
            return _manageWhole
                ? PendingOrders.ToArray()
                : PendingOrders.Where(o => o.SymbolName == _managedSymbol).ToArray();
        }

        private void SetWholeMode()
        {
            _manageWhole = true;
            ResetTrail();
            SaveSettings();
            SetStatus("Managing whole account basket.");
            RefreshUi();
        }

        private void SetSymbolModeFromButton()
        {
            var symbol = _managedSymbol;
            if (string.IsNullOrWhiteSpace(symbol))
                symbol = Positions.Select(p => p.SymbolName).FirstOrDefault() ?? "";

            if (string.IsNullOrWhiteSpace(symbol))
            {
                SetStatus("No symbol available to manage.");
                return;
            }

            SetSymbolMode(symbol);
        }

        private void SetSymbolMode(string symbol)
        {
            _manageWhole = false;
            _managedSymbol = symbol;
            ResetTrail();
            SaveSettings();
            SetStatus($"Managing symbol basket: {symbol}.");
            RefreshUi();
        }

        private void ApplySettings()
        {
            if (!TryReadNonNegative(_tpBox, out _tpCcy) ||
                !TryReadNonNegative(_slBox, out _slCcy) ||
                !TryReadNonNegative(_tpPctBox, out _tpPct) ||
                !TryReadNonNegative(_slPctBox, out _slPct) ||
                !TryReadNonNegative(_trailTriggerBox, out _trailTrigger) ||
                !TryReadNonNegative(_trailDistanceBox, out _trailDistance))
            {
                SetStatus("Invalid setting: use numbers >= 0.");
                return;
            }

            _includePending = _pendingCheck?.IsChecked == true;
            ResetTrail();
            SaveSettings();
            SetStatus("Settings applied.");
            RefreshUi();
        }

        private bool TryReadNonNegative(TextBox? box, out double value)
        {
            value = 0;
            if (box == null)
                return false;
            var text = (box.Text ?? "").Trim().Replace(',', '.');
            return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value) && value >= 0;
        }

        private void EvaluateAutomation()
        {
            if (DateTime.UtcNow < _autoCooldownUntilUtc)
                return;

            var positions = GetManagedPositions();
            if (positions.Length == 0)
            {
                ResetTrail();
                return;
            }

            var signature = BuildBasketSignature(positions);
            if (_trailArmed && !string.Equals(_trailSignature, signature, StringComparison.Ordinal))
                ResetTrail();

            var pnl = positions.Sum(p => p.NetProfit);

            if (_tpCcy > 0 && pnl >= _tpCcy)
            {
                CloseManagedAutomatic($"TP CCY reached ({pnl:F2})");
                return;
            }

            if (_slCcy > 0 && pnl <= -_slCcy)
            {
                CloseManagedAutomatic($"SL CCY reached ({pnl:F2})");
                return;
            }

            var balance = Account.Balance;
            if (_tpPct > 0 && balance > 0 && pnl >= balance * _tpPct / 100.0)
            {
                CloseManagedAutomatic($"TP % reached ({pnl:F2})");
                return;
            }

            if (_slPct > 0 && balance > 0 && pnl <= -(balance * _slPct / 100.0))
            {
                CloseManagedAutomatic($"SL % reached ({pnl:F2})");
                return;
            }

            if (_trailTrigger <= 0 || _trailDistance <= 0)
                return;

            if (!_trailArmed && pnl >= _trailTrigger)
            {
                _trailArmed = true;
                _trailPeak = pnl;
                _trailSignature = signature;
                SaveTrailState(true);
                SetStatus($"Trailing armed at {pnl:F2}.");
            }
            else if (_trailArmed && pnl > _trailPeak)
            {
                _trailPeak = pnl;
                SaveTrailState(false);
            }

            if (_trailArmed && pnl <= _trailPeak - _trailDistance)
                CloseManagedAutomatic($"Trailing exit ({pnl:F2}, peak {_trailPeak:F2})");
        }

        private void CloseManagedAutomatic(string reason)
        {
            var positions = GetManagedPositions();
            if (positions.Length == 0)
                return;

            _autoCooldownUntilUtc = DateTime.UtcNow.AddSeconds(AutoCooldownSeconds);
            var closed = ClosePositions(positions);
            var cancelled = _includePending
                ? CancelOrders(GetManagedPendingOrders())
                : (success: 0, failed: 0, errors: "");
            ResetTrail();
            SetStatus($"{reason} — closed {closed.success}, failed {closed.failed}; " +
                      $"pending cancelled {cancelled.success}, failed {cancelled.failed}." +
                      ErrorSuffix(closed.errors, cancelled.errors));
        }

        private void CloseManagedManual()
        {
            var positions = GetManagedPositions();
            var pending = GetManagedPendingOrders();
            if (positions.Length == 0 && (!_includePending || pending.Length == 0))
            {
                SetStatus("No managed positions or included pending orders to close.");
                return;
            }

            var result = MessageBox.Show(
                $"Close managed basket?\n{positions.Length} positions · {positions.Sum(p => p.Quantity):F2} lots · " +
                $"{(_includePending ? pending.Length : 0)} pending",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            var closed = ClosePositions(positions);
            var cancelled = _includePending ? CancelOrders(pending) : (success: 0, failed: 0, errors: "");
            ResetTrail();
            SetStatus($"Managed close: closed {closed.success}, failed {closed.failed}; " +
                      $"pending cancelled {cancelled.success}, failed {cancelled.failed}." +
                      ErrorSuffix(closed.errors, cancelled.errors));
            RefreshUi();
        }

        private void CloseWholeBasket()
        {
            var positions = Positions.ToArray();
            var pending = PendingOrders.ToArray();
            if (positions.Length == 0 && (!_includePending || pending.Length == 0))
            {
                SetStatus("No positions or included pending orders.");
                return;
            }

            var result = MessageBox.Show(
                $"Close WHOLE account basket?\n{positions.Length} positions · {positions.Sum(p => p.Quantity):F2} lots · " +
                $"{(_includePending ? pending.Length : 0)} pending",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            var closed = ClosePositions(positions);
            var cancelled = _includePending ? CancelOrders(pending) : (success: 0, failed: 0, errors: "");
            ResetTrail();
            SetStatus($"Whole close: closed {closed.success}, failed {closed.failed}; " +
                      $"pending cancelled {cancelled.success}, failed {cancelled.failed}." +
                      ErrorSuffix(closed.errors, cancelled.errors));
            RefreshUi();
        }

        private void CloseBasket(string symbolName, TradeType side)
        {
            var positions = Positions
                .Where(p => p.SymbolName == symbolName && p.TradeType == side)
                .ToArray();
            if (positions.Length == 0)
                return;

            var result = MessageBox.Show(
                $"Close {symbolName} {side} basket?\n{positions.Length} positions · {positions.Sum(p => p.Quantity):F2} lots",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            var closed = ClosePositions(positions);
            var pending = PendingOrders
                .Where(o => o.SymbolName == symbolName && o.TradeType == side)
                .ToArray();
            var cancelled = _includePending ? CancelOrders(pending) : (success: 0, failed: 0, errors: "");
            SetStatus($"{symbolName} {side}: closed {closed.success}, failed {closed.failed}; " +
                      $"pending cancelled {cancelled.success}, failed {cancelled.failed}." +
                      ErrorSuffix(closed.errors, cancelled.errors));
            RefreshUi();
        }

        private (int success, int failed, string errors) ClosePositions(Position[] positions)
        {
            var success = 0;
            var failed = 0;
            var errors = "";
            foreach (var position in positions)
            {
                var result = position.Close();
                if (result.IsSuccessful)
                    success++;
                else
                {
                    failed++;
                    AddTradeError(ref errors, $"Close #{position.Id}", result);
                }
            }
            return (success, failed, errors);
        }

        private (int success, int failed, string errors) CancelOrders(PendingOrder[] orders)
        {
            var success = 0;
            var failed = 0;
            var errors = "";
            foreach (var order in orders)
            {
                var result = order.Cancel();
                if (result.IsSuccessful)
                    success++;
                else
                {
                    failed++;
                    AddTradeError(ref errors, $"Cancel #{order.Id}", result);
                }
            }
            return (success, failed, errors);
        }

        private void AddTradeError(ref string errors, string context, TradeResult result)
        {
            if (result.IsSuccessful)
                return;

            var detail = $"{context}: {result.Error?.ToString() ?? "UnknownError"}";
            if (string.IsNullOrWhiteSpace(errors))
                errors = detail;
            else if (errors.Length < 320)
                errors += " | " + detail;
        }

        private string ErrorSuffix(params string[] errors)
        {
            var details = string.Join(" | ", errors.Where(e => !string.IsNullOrWhiteSpace(e)));
            return string.IsNullOrWhiteSpace(details) ? "" : $" Errors: {details}";
        }

        private void CloseHalfManaged(bool applyBreakEven)
        {
            var positions = GetManagedPositions();
            if (positions.Length == 0)
            {
                SetStatus("No managed positions.");
                return;
            }

            var totalLots = positions.Sum(p => p.Quantity);
            var result = MessageBox.Show(
                $"Reduce managed basket by approximately 50%?\n{positions.Length} positions · {totalLots:F2} lots",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            var modified = 0;
            var closed = 0;
            var failed = 0;
            var errors = "";

            foreach (var group in positions.GroupBy(p => new { p.SymbolName, p.TradeType }))
            {
                var ordered = group.OrderByDescending(p => p.VolumeInUnits).ToArray();
                var symbol = ordered[0].Symbol;
                var totalVolume = ordered.Sum(p => p.VolumeInUnits);

                // Keep at least 50% of the basket. Rounding UP prevents the action
                // from closing more than requested when broker volume steps are coarse.
                var targetRemaining = symbol.NormalizeVolumeInUnits(totalVolume / 2.0, RoundingMode.Up);
                targetRemaining = Math.Min(totalVolume, Math.Max(0, targetRemaining));

                var allocationLeft = targetRemaining;
                foreach (var position in ordered)
                {
                    var keep = Math.Min(position.VolumeInUnits, allocationLeft);
                    keep = symbol.NormalizeVolumeInUnits(keep, RoundingMode.Down);

                    if (keep >= symbol.VolumeInUnitsMin)
                    {
                        allocationLeft -= keep;
                        if (keep < position.VolumeInUnits)
                        {
                            var tradeResult = position.ModifyVolume(keep);
                            if (tradeResult.IsSuccessful)
                                modified++;
                            else
                            {
                                failed++;
                                AddTradeError(ref errors, $"Resize #{position.Id}", tradeResult);
                            }
                        }
                    }
                    else
                    {
                        var tradeResult = position.Close();
                        if (tradeResult.IsSuccessful)
                            closed++;
                        else
                        {
                            failed++;
                            AddTradeError(ref errors, $"Close #{position.Id}", tradeResult);
                        }
                    }
                }
            }

            if (applyBreakEven)
                ApplyBreakEven(false);

            SetStatus($"50% reduction: {modified} resized, {closed} closed, {failed} failed." +
                      ErrorSuffix(errors));
            RefreshUi();
        }

        private void ApplyBreakEven(bool showMessage)
        {
            var positions = GetManagedPositions();
            if (positions.Length == 0)
            {
                SetStatus("No managed positions for BE.");
                return;
            }

            var success = 0;
            var skipped = 0;
            var rejected = 0;
            var errors = "";
            foreach (var group in positions.GroupBy(p => new { p.SymbolName, p.TradeType }))
            {
                var totalVolume = group.Sum(p => p.VolumeInUnits);
                if (totalVolume <= 0)
                    continue;

                var be = group.Sum(p => p.EntryPrice * p.VolumeInUnits) / totalVolume;
                var first = group.First();
                var valid = group.Key.TradeType == TradeType.Buy
                    ? first.Symbol.Bid > be
                    : first.Symbol.Ask < be;

                if (!valid)
                {
                    skipped += group.Count();
                    continue;
                }

                foreach (var position in group)
                {
                    var tradeResult = position.ModifyStopLossPrice(be);
                    if (tradeResult.IsSuccessful)
                        success++;
                    else
                    {
                        rejected++;
                        AddTradeError(ref errors, $"BE #{position.Id}", tradeResult);
                    }
                }
            }

            SetStatus($"Break even: {success} updated, {skipped} skipped (price not beyond BE), {rejected} rejected." +
                      ErrorSuffix(errors));
            if (showMessage)
                RefreshUi();
        }

        private void ResetTrail()
        {
            var changed = _trailArmed || _trailPeak != 0 || !string.IsNullOrEmpty(_trailSignature);
            _trailArmed = false;
            _trailPeak = 0;
            _trailSignature = "";
            if (changed)
                SaveTrailState(true);
        }

        private string BuildBasketSignature(Position[] positions)
        {
            return string.Join("|", positions
                .OrderBy(p => p.Id)
                .Select(p => $"{p.Id}:{p.SymbolName}:{p.TradeType}:{p.VolumeInUnits:0.########}"));
        }

        private void SaveTrailState(bool force)
        {
            var now = DateTime.UtcNow;
            if (!force && (now - _lastTrailPersistUtc).TotalSeconds < 5)
                return;

            LocalStorage.SetString("Trail Armed", _trailArmed ? "1" : "0", LocalStorageScope.Type);
            LocalStorage.SetString("Trail Peak", _trailPeak.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
            LocalStorage.SetString("Trail Signature", _trailSignature ?? "", LocalStorageScope.Type);
            LocalStorage.Flush(LocalStorageScope.Type);
            _lastTrailPersistUtc = now;
        }

        private void SetStatus(string text)
        {
            if (_statusText != null)
                _statusText.Text = text;
        }
        private void LoadSettings()
        {
            _manageWhole = ReadBool("Mode Whole", true);
            _proMode = ReadBool("Pro Mode", true);
            _managedSymbol = LocalStorage.GetString("Managed Symbol", LocalStorageScope.Type) ?? "";
            _includePending = ReadBool("Include Pending", false);
            _tpCcy = ReadDouble("TP CCY");
            _slCcy = ReadDouble("SL CCY");
            _tpPct = ReadDouble("TP Percent");
            _slPct = ReadDouble("SL Percent");
            _trailTrigger = ReadDouble("Trail Trigger");
            _trailDistance = ReadDouble("Trail Distance");
            _trailArmed = ReadBool("Trail Armed", false);
            _trailPeak = ReadDouble("Trail Peak");
            _trailSignature = LocalStorage.GetString("Trail Signature", LocalStorageScope.Type) ?? "";
        }

        private void SaveSettings()
        {
            LocalStorage.SetString("Mode Whole", _manageWhole ? "1" : "0", LocalStorageScope.Type);
            LocalStorage.SetString("Pro Mode", _proMode ? "1" : "0", LocalStorageScope.Type);
            LocalStorage.SetString("Managed Symbol", _managedSymbol ?? "", LocalStorageScope.Type);
            LocalStorage.SetString("Include Pending", _includePending ? "1" : "0", LocalStorageScope.Type);
            LocalStorage.SetString("TP CCY", _tpCcy.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
            LocalStorage.SetString("SL CCY", _slCcy.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
            LocalStorage.SetString("TP Percent", _tpPct.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
            LocalStorage.SetString("SL Percent", _slPct.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
            LocalStorage.SetString("Trail Trigger", _trailTrigger.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
            LocalStorage.SetString("Trail Distance", _trailDistance.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
            LocalStorage.Flush(LocalStorageScope.Type);
        }

        private bool ReadBool(string key, bool defaultValue)
        {
            var value = LocalStorage.GetString(key, LocalStorageScope.Type);
            if (string.IsNullOrWhiteSpace(value))
                return defaultValue;
            return value == "1" || value.Equals("true", StringComparison.OrdinalIgnoreCase);
        }

        private double ReadDouble(string key)
        {
            var value = LocalStorage.GetString(key, LocalStorageScope.Type);
            if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) && parsed >= 0)
                return parsed;
            return 0;
        }
    }
}
