using System;
using System.Linq;
using cAlgo.API;

namespace cAlgo.Plugins
{
    [Plugin(AccessRights = AccessRights.None)]
    public class BasketCommanderNativePoc : Plugin
    {
        private StackPanel _root;
        private StackPanel _body;

        protected override void OnStart()
        {
            var tab = TradeWatch.AddTab("Basket Commander Native");
            _root = new StackPanel
            {
                Orientation = Orientation.Vertical,
                Margin = 10
            };
            tab.Child = _root;

            Timer.Start(TimeSpan.FromSeconds(1));
            RefreshUi();
        }

        protected override void OnTimer()
        {
            RefreshUi();
        }
        private void RefreshUi()
        {
            if (_body != null && _root.HasChild(_body))
                _root.RemoveChild(_body);

            _body = new StackPanel
            {
                Orientation = Orientation.Vertical
            };

            _body.AddChild(new TextBlock
            {
                Text = $"Balance {Account.Balance:F2} {Account.Asset.Name}   " +
                       $"Equity {Account.Equity:F2}   Margin {Account.Margin:F2}",
                FontSize = 14,
                Margin = 5
            });

            var groups = Positions
                .GroupBy(p => new { p.SymbolName, p.TradeType })
                .OrderBy(g => g.Key.SymbolName)
                .ThenBy(g => g.Key.TradeType)
                .ToArray();

            if (groups.Length == 0)
            {
                _body.AddChild(new TextBlock
                {
                    Text = "No open positions",
                    Margin = 5
                });
            }

            foreach (var group in groups)
            {
                var symbol = group.Key.SymbolName;
                var side = group.Key.TradeType;
                var count = group.Count();
                var lots = group.Sum(p => p.Quantity);
                var pnl = group.Sum(p => p.NetProfit);

                var row = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Margin = 5
                };

                row.AddChild(new TextBlock
                {
                    Text = $"{symbol} {side}  |  {count} pos  |  {lots:F2} lots  |  P/L {pnl:F2}",
                    Width = 430,
                    Margin = 5
                });
                var closeButton = new Button
                {
                    Text = "CLOSE BASKET",
                    Width = 140,
                    Margin = 5
                };

                closeButton.Click += _ => CloseBasket(symbol, side);
                row.AddChild(closeButton);
                _body.AddChild(row);
            }

            _root.AddChild(_body);
        }

        private void CloseBasket(string symbolName, TradeType side)
        {
            var positions = Positions
                .Where(p => p.SymbolName == symbolName && p.TradeType == side)
                .ToArray();

            if (positions.Length == 0)
                return;

            var lots = positions.Sum(p => p.Quantity);
            var result = MessageBox.Show(
                $"Close {symbolName} {side} basket?\n{positions.Length} positions · {lots:F2} lots",
                "Basket Commander",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (result != MessageBoxResult.Yes)
                return;

            foreach (var position in positions)
                position.Close();

            RefreshUi();
        }
    }
}
