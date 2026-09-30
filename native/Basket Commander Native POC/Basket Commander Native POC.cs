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
        private TextBlock? _statusText;
        private TextBox? _tpBox;
        private TextBox? _slBox;
        private TextBox? _trailTriggerBox;
        private TextBox? _trailDistanceBox;
        private CheckBox? _pendingCheck;

        private bool _manageWhole = true;
        private string _managedSymbol = "";
        private bool _includePending;
        private double _tpCcy;
        private double _slCcy;
        private double _trailTrigger;
        private double _trailDistance;
        private bool _trailArmed;
        private double _trailPeak;

        protected override void OnStart()
        {
            LoadSettings();
            var tab = TradeWatch.AddTab("Basket Commander Native");
            _root = new StackPanel { Orientation = Orientation.Vertical, Margin = 10 };
            tab.Child = _root;
            BuildStaticUi();
            Timer.Start(TimeSpan.FromSeconds(1));
            RefreshUi();
        }

        protected override void OnTimer()
        {
            EvaluateAutomation();
            RefreshUi();
        }

        private void BuildStaticUi()
        {
            if (_root == null)
                return;

            _accountText = new TextBlock { FontSize = 14, Margin = 5 };
            _scopeText = new TextBlock { FontSize = 13, Margin = 5 };
            _managedText = new TextBlock { Margin = 5 };
            _trailText = new TextBlock { Margin = 5 };
            _statusText = new TextBlock { Margin = 5 };
            _root.AddChild(_accountText);
            _root.AddChild(_scopeText);
            _root.AddChild(_managedText);
            _root.AddChild(_trailText);
            _root.AddChild(_statusText);

            var modeRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            var wholeButton = new Button { Text = "MANAGE WHOLE BASKET", Width = 190, Margin = 3 };
            wholeButton.Click += _ => SetWholeMode();
            modeRow.AddChild(wholeButton);
            _root.AddChild(modeRow);

            var settingsRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            _tpBox = MakeBox(_tpCcy);
            _slBox = MakeBox(_slCcy);
            _trailTriggerBox = MakeBox(_trailTrigger);
            _trailDistanceBox = MakeBox(_trailDistance);
            AddLabeled(settingsRow, "TP CCY", _tpBox);
            AddLabeled(settingsRow, "SL CCY", _slBox);
            AddLabeled(settingsRow, "Trail trigger", _trailTriggerBox);
            AddLabeled(settingsRow, "Trail distance", _trailDistanceBox);
            _root.AddChild(settingsRow);

            var settingsActions = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
            var applyButton = new Button { Text = "APPLY SETTINGS", Width = 150, Margin = 3 };
            applyButton.Click += _ => ApplySettings();
            _pendingCheck = new CheckBox { Text = "Include pending orders", IsChecked = _includePending, Margin = 5 };
            _pendingCheck.Click += args =>
            {
                _includePending = args.CheckBox.IsChecked == true;
                SaveSettings();
            };
            settingsActions.AddChild(applyButton);
            settingsActions.AddChild(_pendingCheck);
            _root.AddChild(settingsActions);

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

        private void RefreshUi()
        {
            if (_root == null || _accountText == null || _scopeText == null ||
                _managedText == null || _trailText == null)
                return;

            _accountText.Text =
                $"Balance {Account.Balance:F2} {Account.Asset.Name}   Equity {Account.Equity:F2}   Margin {Account.Margin:F2}";

            var managed = GetManagedPositions();
            var pnl = managed.Sum(p => p.NetProfit);
            var lots = managed.Sum(p => p.Quantity);
            var pendingCount = GetManagedPendingOrders().Length;
            _scopeText.Text = _manageWhole
                ? "MODE: WHOLE ACCOUNT"
                : $"MODE: SYMBOL — {_managedSymbol}";
            _managedText.Text =
                $"Managed: {managed.Length} positions · {lots:F2} lots · P/L {pnl:F2} · Pending {pendingCount}";
            _trailText.Text = _trailArmed
                ? $"Trailing ARMED · peak {_trailPeak:F2} · close at {_trailPeak - _trailDistance:F2}"
                : "Trailing not armed";

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
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = 3 };
                row.AddChild(new TextBlock
                {
                    Text = $"{symbol} {side} | {group.Count()} pos | {group.Sum(p => p.Quantity):F2} lots | P/L {group.Sum(p => p.NetProfit):F2}",
                    Width = 390,
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
            var positions = GetManagedPositions();
            if (positions.Length == 0)
            {
                ResetTrail();
                return;
            }

            var pnl = positions.Sum(p => p.NetProfit);

            if (_tpCcy > 0 && pnl >= _tpCcy)
            {
                CloseManagedAutomatic($"TP reached ({pnl:F2})");
                return;
            }

            if (_slCcy > 0 && pnl <= -_slCcy)
            {
                CloseManagedAutomatic($"SL reached ({pnl:F2})");
                return;
            }

            if (_trailTrigger <= 0 || _trailDistance <= 0)
                return;

            if (!_trailArmed && pnl >= _trailTrigger)
            {
                _trailArmed = true;
                _trailPeak = pnl;
                SetStatus($"Trailing armed at {pnl:F2}.");
            }
            else if (_trailArmed && pnl > _trailPeak)
            {
                _trailPeak = pnl;
            }

            if (_trailArmed && pnl <= _trailPeak - _trailDistance)
                CloseManagedAutomatic($"Trailing exit ({pnl:F2}, peak {_trailPeak:F2})");
        }

        private void CloseManagedAutomatic(string reason)
        {
            var positions = GetManagedPositions();
            if (positions.Length == 0)
                return;

            ClosePositions(positions);
            if (_includePending)
                CancelOrders(GetManagedPendingOrders());
            ResetTrail();
            SetStatus(reason + " — managed basket closed.");
        }

        private void CloseManagedManual()
        {
            var positions = GetManagedPositions();
            if (positions.Length == 0)
            {
                SetStatus("No managed positions to close.");
                return;
            }

            var result = MessageBox.Show(
                $"Close managed basket?\n{positions.Length} positions · {positions.Sum(p => p.Quantity):F2} lots",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            ClosePositions(positions);
            if (_includePending)
                CancelOrders(GetManagedPendingOrders());
            ResetTrail();
            SetStatus("Managed basket closed.");
            RefreshUi();
        }

        private void CloseWholeBasket()
        {
            var positions = Positions.ToArray();
            if (positions.Length == 0)
            {
                SetStatus("No open positions.");
                return;
            }

            var result = MessageBox.Show(
                $"Close WHOLE account basket?\n{positions.Length} positions · {positions.Sum(p => p.Quantity):F2} lots",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            ClosePositions(positions);
            if (_includePending)
                CancelOrders(PendingOrders.ToArray());
            ResetTrail();
            SetStatus("Whole account basket closed.");
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

            ClosePositions(positions);
            if (_includePending)
                CancelOrders(PendingOrders
                    .Where(o => o.SymbolName == symbolName && o.TradeType == side)
                    .ToArray());
            SetStatus($"{symbolName} {side} basket closed.");
            RefreshUi();
        }

        private void ClosePositions(Position[] positions)
        {
            foreach (var position in positions)
                position.Close();
        }

        private void CancelOrders(PendingOrder[] orders)
        {
            foreach (var order in orders)
                order.Cancel();
        }

        private void CloseHalfManaged(bool applyBreakEven)
        {
            var positions = GetManagedPositions();
            if (positions.Length == 0)
            {
                SetStatus("No managed positions.");
                return;
            }

            var result = MessageBox.Show(
                $"Reduce managed basket by 50%?\n{positions.Length} positions",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            var changed = 0;
            var skipped = 0;
            foreach (var position in positions)
            {
                var target = position.Symbol.NormalizeVolumeInUnits(position.VolumeInUnits / 2.0, RoundingMode.Down);
                if (target >= position.Symbol.VolumeInUnitsMin && target < position.VolumeInUnits)
                {
                    var tradeResult = position.ModifyVolume(target);
                    if (tradeResult.IsSuccessful)
                        changed++;
                    else
                        skipped++;
                }
                else
                {
                    skipped++;
                }
            }

            if (applyBreakEven)
                ApplyBreakEven(false);

            SetStatus($"50% reduction: {changed} changed, {skipped} skipped (min volume/step or broker rejection).");
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
                        skipped++;
                }
            }

            SetStatus($"Break even: {success} updated, {skipped} skipped/rejected.");
            if (showMessage)
                RefreshUi();
        }

        private void ResetTrail()
        {
            _trailArmed = false;
            _trailPeak = 0;
        }

        private void SetStatus(string text)
        {
            if (_statusText != null)
                _statusText.Text = text;
        }
        private void LoadSettings()
        {
            _manageWhole = ReadBool("Mode Whole", true);
            _managedSymbol = LocalStorage.GetString("Managed Symbol", LocalStorageScope.Type) ?? "";
            _includePending = ReadBool("Include Pending", false);
            _tpCcy = ReadDouble("TP CCY");
            _slCcy = ReadDouble("SL CCY");
            _trailTrigger = ReadDouble("Trail Trigger");
            _trailDistance = ReadDouble("Trail Distance");
        }

        private void SaveSettings()
        {
            LocalStorage.SetString("Mode Whole", _manageWhole ? "1" : "0", LocalStorageScope.Type);
            LocalStorage.SetString("Managed Symbol", _managedSymbol ?? "", LocalStorageScope.Type);
            LocalStorage.SetString("Include Pending", _includePending ? "1" : "0", LocalStorageScope.Type);
            LocalStorage.SetString("TP CCY", _tpCcy.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
            LocalStorage.SetString("SL CCY", _slCcy.ToString(CultureInfo.InvariantCulture), LocalStorageScope.Type);
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
