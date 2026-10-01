#property strict
#property version   "1.00"
// v1.17: independent BOTH/BUY/SELL settings; cycle ledger persisted in MQL5/Files.
#property description "Basket Commander PRO MT5: advanced basket, position and account-equity trade management utility."

#include <Trade/Trade.mqh>

CTrade trade;

enum ENUM_BREAKEVEN_MODE
{
   BREAKEVEN_OFF = 0,
   BREAKEVEN_RECOVERY = 1,
   BREAKEVEN_PROTECT = 2
};

// Inputs: -1 manages all magic numbers; 0 selects manual trades.
// All controls, including CLOSE BASKET, respect symbol, magic and direction.
// A cycle begins with the first observed eligible position and ends when flat.
// History of adopted open positions (including earlier partial exits) is included.
// Run only one manager for an overlapping symbol/magic basket.
input long                    InpMagicNumber = 990126;
input bool                    InpSeparateSides = false;
input double                  InpSideDefaultTP = 0.0;
input double                  InpSideDefaultSL = 0.0;

input ENUM_BASE_CORNER        InpPanelCorner            = CORNER_LEFT_UPPER;
input int                     InpPanelX                 = 1;
input int                     InpPanelY                 = 80;
input double                  InpDefaultPosUSD          = 0.0; // Basket TP (account CCY; 0 = off)
input double                  InpDefaultNegUSD          = 0.0; // Basket SL magnitude ($, 0 = off)
input bool                    InpDefaultNegProfitLock   = false;  // false: -loss limit; true: +protected-profit floor
input double                  InpDefaultTrailTriggerUSD = 0.0;   // Trail trigger (CCY; 0 = off)
input double                  InpDefaultTrailDistanceUSD = 0.0;  // Trail distance (CCY; 0 = off)
input int                     InpSlippagePoints         = 20;

input bool                    InpUseTesterInputs        = true;
input double                  InpTesterPosUSD           = 0.0;
input double                  InpTesterNegUSD           = 0.0;
input bool                    InpTesterNegProfitLock    = false;
input double                  InpTesterTrailTriggerUSD  = 0.0;
input double                  InpTesterTrailDistanceUSD = 0.0;

const string PREFIX = "BCPRO100_";
const double BREAKEVEN_LEVEL_USD = 0.0;

double gPositiveUSD    = 5000.0;
double gNegativeUSD    = 10000.0;
bool   gNegativeProfitLock = false;
bool   gBasketSLArmed = false;
double gTrailTriggerUSD = 0.0;
double gTrailDistanceUSD = 0.0;
bool   gProfitTrailArmed = false;
double gProfitTrailPeakUSD = 0.0;
ENUM_BREAKEVEN_MODE gBreakevenMode = BREAKEVEN_OFF;
bool   gTesterMode     = false;
bool   gVisualMode     = false;
bool   gPanelCreated   = false;
bool   gHalfCloseBusy = false;
ulong  gHalfCloseFinishedMs = 0;
string gHalfCloseStatus = "50%: current symbol; lot step rounded down";
bool   gManageWholeBasket = false; // false=current chart symbol; true=all symbols for manual CLOSE BASKET
bool   gObjectCreateEventWasEnabled = false;
string gHistoryBackChanged[];
int    gHistoryRescanTicks = 0;
int    gHistoryInitialScanCursor = -2; // -2 = not started; -1 = finished

// Exits use cycle realized P/L + floating profit + open swap, including deal costs.
// Half-closing does not move monetary thresholds or the existing trailing peak.
int gScope = 0; // 0 combined, 1 BUY, 2 SELL
bool gSplit = false;
bool gBackgroundCheck = false;
bool gHistoryDirty = true;
string gLiveSignature = "";
bool gLedgerWritePending[3];
bool gPendingHalfBE[3];
bool gClosingScope[3];
ulong gLastCloseAttempt[3];
ulong gLastHistoryMs = 0;
double gLastHalfFilled = 0.0;
string gStateKey = "";
struct ScopeState
{
   double tp, sl, trigger, distance, peak;
   bool profitLock, slArmed, trailArmed;
   ENUM_BREAKEVEN_MODE be;
};
ScopeState gScopes[3];
struct CycleLedger
{
   string ids;
   double realized, lastResult;
   bool ready;
};
CycleLedger gLedger[3];

// Account-wide equity exits. Values are absolute account-currency levels.
input double InpAccountEquityTP = 0.0;
input double InpAccountEquitySL = 0.0;
double gAccountTP=0.0, gAccountSL=0.0;
bool gAccountClosing=false;
ulong gAccountCloseAttempt=0;
long gEquityLogin=0;
string gEquityServer="";

bool EquityLimitsValid(double tp,double sl)
{
   return MathIsValidNumber(tp) && MathIsValidNumber(sl) && tp>=0 && sl>=0 &&
          (tp==0 || sl==0 || sl<tp);
}
int AccountEquityHit(double equity,double tp,double sl)
{
   if(!MathIsValidNumber(equity)) return 0;
   if(sl>0 && equity<=sl) return -1;
   if(tp>0 && equity>=tp) return 1;
   return 0;
}
void SaveAccountEquity()
{
   if(gTesterMode) return;
   GlobalVariableSet(gStateKey+"_EQTP",gAccountTP);
   GlobalVariableSet(gStateKey+"_EQSL",gAccountSL);
   GlobalVariableSet(gStateKey+"_EQCLOSE",gAccountClosing ? 1.0 : 0.0);
   GlobalVariablesFlush();
}
bool InitAccountEquity()
{
   gEquityLogin=AccountInfoInteger(ACCOUNT_LOGIN);
   gEquityServer=AccountInfoString(ACCOUNT_SERVER);
   gAccountTP=InpAccountEquityTP; gAccountSL=InpAccountEquitySL;
   if(!EquityLimitsValid(gAccountTP,gAccountSL)) return false;
   if(!gTesterMode)
   {
      if(GlobalVariableCheck(gStateKey+"_EQTP")) gAccountTP=GlobalVariableGet(gStateKey+"_EQTP");
      if(GlobalVariableCheck(gStateKey+"_EQSL")) gAccountSL=GlobalVariableGet(gStateKey+"_EQSL");
      gAccountClosing=GlobalVariableCheck(gStateKey+"_EQCLOSE") && GlobalVariableGet(gStateKey+"_EQCLOSE")!=0;
   }
   return EquityLimitsValid(gAccountTP,gAccountSL);
}
bool ParseEquityLevel(string text,double &value)
{
   text=TrimString(text); StringReplace(text,",",".");
   if(StringLen(text)==0) return false;
   int digits=0,dots=0;
   for(int i=0;i<StringLen(text);i++)
   {
      ushort c=StringGetCharacter(text,i);
      if(c>='0' && c<='9') digits++;
      else if(c=='.') dots++;
      else return false;
   }
   if(digits==0 || dots>1) return false;
   value=StringToDouble(text);
   return MathIsValidNumber(value) && value>=0 && value<=1e12;
}
void SyncAccountEquityFields()
{
   ObjectSetString(0,ObjName("EDIT_EQTP"),OBJPROP_TEXT,DoubleToString(gAccountTP,2));
   ObjectSetString(0,ObjName("EDIT_EQSL"),OBJPROP_TEXT,DoubleToString(gAccountSL,2));
}
void CommitAccountEquity(const string field)
{
   double value=0,tp=gAccountTP,sl=gAccountSL;
   bool valid=ParseEquityLevel(ObjectGetString(0,field,OBJPROP_TEXT),value);
   if(field==ObjName("EDIT_EQTP")) tp=value; else sl=value;
   if(valid && EquityLimitsValid(tp,sl) && !gAccountClosing)
   {
      gAccountTP=tp; gAccountSL=sl; SaveAccountEquity();
      Print("Account equity limits: TP=",tp," SL=",sl,". ALL symbols and magic numbers.");
   }
   else Print("Equity limit ignored: enter a non-negative number; SL must be below TP. Closing cannot be cancelled.");
   SyncAccountEquityFields();
}
bool ProcessAccountEquity()
{
   if(AccountInfoInteger(ACCOUNT_LOGIN)!=gEquityLogin || AccountInfoString(ACCOUNT_SERVER)!=gEquityServer)
      return true; // Never carry these settings to another account.
   if(!gAccountClosing)
   {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return false;
      if(PositionsTotal()==0 && OrdersTotal()==0) return false;
      int hit=AccountEquityHit(AccountInfoDouble(ACCOUNT_EQUITY),gAccountTP,gAccountSL);
      if(hit==0) return false;
      gAccountClosing=true; SaveAccountEquity(); // Persist before sending trade requests.
      Print("ACCOUNT EQUITY ",hit>0 ? "TP" : "SL"," triggered at ",AccountInfoDouble(ACCOUNT_EQUITY),"; closing ALL account trades.");
   }
   if(PositionsTotal()==0 && OrdersTotal()==0)
   {
      gAccountClosing=false; SaveAccountEquity();
      Print("Account equity exit complete; account is flat. Limits remain active.");
      return true;
   }
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return true;
   ulong now=GetTickCount64();
   if(gAccountCloseAttempt!=0 && now-gAccountCloseAttempt<1000) return true;
   gAccountCloseAttempt=now;
   // Cancel entry orders first. Retry remaining orders/positions until account is flat.
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0) continue;
      if(!trade.OrderDelete(ticket) || trade.ResultRetcode()!=TRADE_RETCODE_DONE)
         Print("Account equity order delete ",ticket,": ",trade.ResultRetcodeDescription());
   }
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      if(!trade.SetTypeFillingBySymbol(symbol)) continue;
      if(!trade.PositionClose(ticket) || trade.ResultRetcode()!=TRADE_RETCODE_DONE)
         Print("Account equity close ",ticket," ",symbol,": ",trade.ResultRetcodeDescription());
   }
   gHistoryDirty=true;
   return true;
}

string ScopeName()
{
   return gScope == 1 ? "BUY" : (gScope == 2 ? "SELL" : "BOTH");
}
string ManageModeName()
{
   return gManageWholeBasket ? "WHOLE BASKET" : "SYMBOL BASKET";
}
bool SelectedPositionMatchesManual(const int scope)
{
   if(!gManageWholeBasket && PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if(InpMagicNumber >= 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) return false;
   long type = PositionGetInteger(POSITION_TYPE);
   return scope == 0 || (scope == 1 && type == POSITION_TYPE_BUY) ||
          (scope == 2 && type == POSITION_TYPE_SELL);
}
bool SelectedOrderMatchesManual()
{
   if(!gManageWholeBasket && OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   if(InpMagicNumber >= 0 && OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) return false;
   long type = OrderGetInteger(ORDER_TYPE);
   bool buy = type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT;
   bool sell = type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT;
   return (gScope == 0 && (buy || sell)) || (gScope == 1 && buy) || (gScope == 2 && sell);
}
int ManagedPositionCount()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && PositionSelectByTicket(ticket) && SelectedPositionMatchesManual(gScope)) count++;
   }
   return count;
}
double ManagedFloatingProfit()
{
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket) || !SelectedPositionMatchesManual(gScope)) continue;
      total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return total;
}
void SaveManageMode()
{
   if(gTesterMode || gStateKey == "") return;
   GlobalVariableSet(gStateKey + "_MANAGE_WHOLE", gManageWholeBasket ? 1.0 : 0.0);
   GlobalVariablesFlush();
}
bool SelectedPositionMatches(const int scope)
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if(InpMagicNumber >= 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) return false;
   long type = PositionGetInteger(POSITION_TYPE);
   return scope == 0 || (scope == 1 && type == POSITION_TYPE_BUY) ||
          (scope == 2 && type == POSITION_TYPE_SELL);
}
void CaptureScope()
{
   gScopes[gScope].tp = gPositiveUSD;
   gScopes[gScope].sl = gNegativeUSD;
   gScopes[gScope].profitLock = gNegativeProfitLock;
   gScopes[gScope].slArmed = gBasketSLArmed;
   gScopes[gScope].trigger = gTrailTriggerUSD;
   gScopes[gScope].distance = gTrailDistanceUSD;
   gScopes[gScope].trailArmed = gProfitTrailArmed;
   gScopes[gScope].peak = gProfitTrailPeakUSD;
   gScopes[gScope].be = gBreakevenMode;
}
void ActivateScope(const int scope)
{
   gScope = scope;
   gPositiveUSD = gScopes[scope].tp;
   gNegativeUSD = gScopes[scope].sl;
   gNegativeProfitLock = gScopes[scope].profitLock;
   gBasketSLArmed = gScopes[scope].slArmed;
   gTrailTriggerUSD = gScopes[scope].trigger;
   gTrailDistanceUSD = gScopes[scope].distance;
   gProfitTrailArmed = gScopes[scope].trailArmed;
   gProfitTrailPeakUSD = gScopes[scope].peak;
   gBreakevenMode = gScopes[scope].be;
}


void   UpdatePanelStatus();
void   SavePersistentSettings();
int    CurrentSymbolPositionCount();

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string ObjName(const string suffix)
{
   return PREFIX + suffix;
}
//+------------------------------------------------------------------+
bool IsTradeHistoryObject(const string name)
{
   return StringFind(name, "autotrade") == 0;
}
//+------------------------------------------------------------------+
bool PutTradeHistoryObjectBehindPanel(const string name)
{
   if(!IsTradeHistoryObject(name))
      return false;

   ResetLastError();
   long wasBack = ObjectGetInteger(0, name, OBJPROP_BACK);
   if(GetLastError() != 0 || wasBack != 0)
      return false;

   if(!ObjectSetInteger(0, name, OBJPROP_BACK, true))
      return false;

   int n = ArraySize(gHistoryBackChanged);
   ArrayResize(gHistoryBackChanged, n + 1);
   gHistoryBackChanged[n] = name;
   return true;
}
//+------------------------------------------------------------------+
void PutRecentTradeHistoryBehindPanel()
{
   int total = ObjectsTotal(0, 0, -1);
   if(total <= 0)
      return;

   int lowest = MathMax(0, total - 32);
   bool changed = false;
   for(int i = total - 1; i >= lowest; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(name != "" && PutTradeHistoryObjectBehindPanel(name))
         changed = true;
   }

   if(changed)
      ChartRedraw(0);
}
//+------------------------------------------------------------------+
void ContinueInitialTradeHistoryScan()
{
   if(gHistoryInitialScanCursor == -1)
      return;

   if(gHistoryInitialScanCursor == -2)
   {
      gHistoryInitialScanCursor = ObjectsTotal(0, 0, -1) - 1;
      if(gHistoryInitialScanCursor < 0)
      {
         gHistoryInitialScanCursor = -1;
         return;
      }
   }

   bool changed = false;
   int processed = 0;
   while(gHistoryInitialScanCursor >= 0 && processed < 48)
   {
      string name = ObjectName(0, gHistoryInitialScanCursor, 0, -1);
      gHistoryInitialScanCursor--;
      processed++;
      if(name != "" && PutTradeHistoryObjectBehindPanel(name))
         changed = true;
   }

   if(gHistoryInitialScanCursor < 0)
      gHistoryInitialScanCursor = -1;

   if(changed)
      ChartRedraw(0);
}
//+------------------------------------------------------------------+
void RestoreTradeHistoryObjectLayer()
{
   bool changed = false;
   for(int i = 0; i < ArraySize(gHistoryBackChanged); i++)
   {
      string name = gHistoryBackChanged[i];
      if(name == "" || ObjectFind(0, name) < 0)
         continue;
      if(ObjectSetInteger(0, name, OBJPROP_BACK, false))
         changed = true;
   }
   ArrayResize(gHistoryBackChanged, 0);
   if(changed)
      ChartRedraw(0);
}
//+------------------------------------------------------------------+
string TrimString(string text)
{
   StringTrimLeft(text);
   StringTrimRight(text);
   return text;
}
//+------------------------------------------------------------------+
int DigitsFromStep(double step)
{
   string s = DoubleToString(step, 8);
   int p = StringFind(s, ".");
   if(p < 0)
      return 0;

   int digits = StringLen(s) - p - 1;
   while(digits > 0 && StringGetCharacter(s, p + digits) == '0')
      digits--;

   if(digits < 0)
      digits = 0;

   return digits;
}
//+------------------------------------------------------------------+
int VolumeDigits()
{
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepVol <= 0.0)
      stepVol = 0.01;

   return DigitsFromStep(stepVol);
}
//+------------------------------------------------------------------+
string FormatVolume(const double volume)
{
   return DoubleToString(volume, VolumeDigits());
}
//+------------------------------------------------------------------+
string FormatNegativeBasketField()
{
   string value = DoubleToString(gNegativeUSD, 2);
   if(gNegativeUSD <= 0.0)
      return value;

   return gNegativeProfitLock ? "+" + value : "-" + value;
}
//+------------------------------------------------------------------+
string FormatSignedUSD(const double value)
{
   if(value > 0.0)
      return "+" + DoubleToString(value, 2);

   return DoubleToString(value, 2);
}
//+------------------------------------------------------------------+
bool ParseSignedBasketLimit(string text,
                            double &magnitude,
                            bool &profitLock)
{
   text = TrimString(text);
   magnitude = 0.0;
   profitLock = false;

   // Zero disables the limit and is the only value allowed without a sign.
   if(text == "0" || text == "0.0" || text == "0.00")
      return true;

   if(StringLen(text) < 2)
      return false;

   string sign = StringSubstr(text, 0, 1);
   if(sign != "+" && sign != "-")
      return false;

   string numberText = StringSubstr(text, 1);
   bool hasDigit = false;
   bool hasDecimalPoint = false;

   for(int i = 0; i < StringLen(numberText); i++)
   {
      ushort c = StringGetCharacter(numberText, i);

      if(c >= '0' && c <= '9')
      {
         hasDigit = true;
         continue;
      }

      if(c == '.' && !hasDecimalPoint)
      {
         hasDecimalPoint = true;
         continue;
      }

      return false;
   }

   if(!hasDigit)
      return false;

   double parsedValue = StringToDouble(numberText);
   if(parsedValue < 0.0)
      return false;

   magnitude = parsedValue;
   profitLock = (sign == "+" && magnitude > 0.0);
   return true;
}
//+------------------------------------------------------------------+
void ResetProfitTrailState()
{
   gProfitTrailArmed = false;
   gProfitTrailPeakUSD = 0.0;
}
//+------------------------------------------------------------------+
void ResetBasketSLState()
{
   gBasketSLArmed = false;
}
//+------------------------------------------------------------------+
void ResetBreakevenState()
{
   gBreakevenMode = BREAKEVEN_OFF;
}
//+------------------------------------------------------------------+
void UpdateBreakevenButton()
{
   if(!gPanelCreated)
      return;

   string buttonText = "BREAKEVEN: OFF";
   color buttonColor = clrDimGray;
   if(gBreakevenMode == BREAKEVEN_RECOVERY)
   {
      buttonText = "BE: RECOVERY";
      buttonColor = clrSteelBlue;
   }
   else if(gBreakevenMode == BREAKEVEN_PROTECT)
   {
      buttonText = "BE: PROTECT";
      buttonColor = clrForestGreen;
   }

   ObjectSetString(0, ObjName("BTN_BREAKEVEN"), OBJPROP_TEXT, buttonText);
   ObjectSetInteger(0, ObjName("BTN_BREAKEVEN"), OBJPROP_BGCOLOR, buttonColor);
}
//+------------------------------------------------------------------+
bool ProfitTrailSettingsValid()
{
   return (gTrailTriggerUSD > 0.0 && gTrailDistanceUSD > 0.0);
}
//+------------------------------------------------------------------+
double ProfitTrailDistanceUSD()
{
   return gTrailDistanceUSD;
}
//+------------------------------------------------------------------+
double SignedBasketLimitUSD()
{
   return gNegativeProfitLock ? gNegativeUSD : -gNegativeUSD;
}
//+------------------------------------------------------------------+
double ProfitTrailFloorUSD()
{
   if(!gProfitTrailArmed)
      return 0.0;

   return gProfitTrailPeakUSD - ProfitTrailDistanceUSD();
}
//+------------------------------------------------------------------+
string SettingsPrefix()
{
   return gStateKey + "_" + IntegerToString(gScope) + "_";
}
//+------------------------------------------------------------------+
string SettingsKey(const string name)
{
   return SettingsPrefix() + name;
}
//+------------------------------------------------------------------+
void SavePersistentSettings()
{
   if(gTesterMode)
      return;

   GlobalVariableSet(SettingsKey("CLOSING"), gClosingScope[gScope] ? 1.0 : 0.0);
   GlobalVariableSet(SettingsKey("PENDING_BE"), gPendingHalfBE[gScope] ? 1.0 : 0.0);
   GlobalVariableSet(SettingsKey("POS"),            gPositiveUSD);
   GlobalVariableSet(SettingsKey("NEG"),            gNegativeUSD);
   GlobalVariableSet(SettingsKey("NEG_PROFIT_LOCK"),gNegativeProfitLock ? 1.0 : 0.0);
   GlobalVariableSet(SettingsKey("BASKET_SL_ARMED"),gBasketSLArmed ? 1.0 : 0.0);
   GlobalVariableSet(SettingsKey("TRAIL_TRIGGER"),  gTrailTriggerUSD);
   GlobalVariableSet(SettingsKey("TRAIL_DISTANCE"), gTrailDistanceUSD);
   GlobalVariableSet(SettingsKey("TRAIL_ARMED"),    gProfitTrailArmed ? 1.0 : 0.0);
   GlobalVariableSet(SettingsKey("TRAIL_PEAK"),     gProfitTrailPeakUSD);
   GlobalVariableSet(SettingsKey("BREAKEVEN_MODE"), (double)gBreakevenMode);
}
//+------------------------------------------------------------------+
void LoadPersistentSettings()
{
   if(gTesterMode)
      return;

   string key;
   gClosingScope[gScope] = GlobalVariableCheck(SettingsKey("CLOSING")) && GlobalVariableGet(SettingsKey("CLOSING")) != 0.0;
   gPendingHalfBE[gScope] = GlobalVariableCheck(SettingsKey("PENDING_BE")) && GlobalVariableGet(SettingsKey("PENDING_BE")) != 0.0;

   key = SettingsKey("POS");
   if(GlobalVariableCheck(key))
      gPositiveUSD = GlobalVariableGet(key);

   key = SettingsKey("NEG");
   if(GlobalVariableCheck(key))
      gNegativeUSD = GlobalVariableGet(key);

   key = SettingsKey("NEG_PROFIT_LOCK");
   if(GlobalVariableCheck(key))
      gNegativeProfitLock = (GlobalVariableGet(key) != 0.0);

   key = SettingsKey("BASKET_SL_ARMED");
   if(GlobalVariableCheck(key))
      gBasketSLArmed = (GlobalVariableGet(key) != 0.0);

   key = SettingsKey("TRAIL_TRIGGER");
   if(GlobalVariableCheck(key))
      gTrailTriggerUSD = GlobalVariableGet(key);

   key = SettingsKey("TRAIL_DISTANCE");
   if(GlobalVariableCheck(key))
      gTrailDistanceUSD = GlobalVariableGet(key);

   key = SettingsKey("TRAIL_ARMED");
   if(GlobalVariableCheck(key))
      gProfitTrailArmed = (GlobalVariableGet(key) != 0.0);

   key = SettingsKey("TRAIL_PEAK");
   if(GlobalVariableCheck(key))
      gProfitTrailPeakUSD = GlobalVariableGet(key);

   key = SettingsKey("BREAKEVEN_MODE");
   if(GlobalVariableCheck(key))
   {
      int savedBreakevenMode = (int)MathRound(GlobalVariableGet(key));
      gBreakevenMode = (ENUM_BREAKEVEN_MODE)savedBreakevenMode;
   }

   if(gPositiveUSD < 0.0)
      gPositiveUSD = 0.0;
   if(gNegativeUSD < 0.0)
      gNegativeUSD = 0.0;
   if(gTrailTriggerUSD < 0.0)
      gTrailTriggerUSD = 0.0;
   if(gTrailDistanceUSD < 0.0)
      gTrailDistanceUSD = 0.0;
   if(gBreakevenMode != BREAKEVEN_OFF &&
      gBreakevenMode != BREAKEVEN_RECOVERY &&
      gBreakevenMode != BREAKEVEN_PROTECT)
   {
      ResetBreakevenState();
   }
   if(CurrentSymbolPositionCount() == 0)
   {
      ResetProfitTrailState();
      ResetBasketSLState();
      ResetBreakevenState();
   }
   else if(!ProfitTrailSettingsValid() ||
           (gProfitTrailArmed && gProfitTrailPeakUSD < gTrailTriggerUSD))
   {
      ResetProfitTrailState();
   }
   if(!gNegativeProfitLock)
      ResetBasketSLState();
}
//+------------------------------------------------------------------+
void ApplyTesterInputs()
{
   gPositiveUSD     = InpTesterPosUSD;
   gNegativeUSD     = InpTesterNegUSD;
   gNegativeProfitLock = InpTesterNegProfitLock;
   gTrailTriggerUSD = InpTesterTrailTriggerUSD;
   gTrailDistanceUSD = InpTesterTrailDistanceUSD;
   ResetProfitTrailState();
   ResetBasketSLState();
   ResetBreakevenState();
   if(gPositiveUSD < 0.0)
      gPositiveUSD = 0.0;
   if(gNegativeUSD < 0.0)
      gNegativeUSD = 0.0;
   if(gTrailTriggerUSD < 0.0)
      gTrailTriggerUSD = 0.0;
   if(gTrailDistanceUSD < 0.0)
      gTrailDistanceUSD = 0.0;
}
//+------------------------------------------------------------------+
void SyncPanelFields()
{
   if(!gPanelCreated)
      return;

   UpdateBreakevenButton();

   ObjectSetString(0, ObjName("EDIT_POS"),   OBJPROP_TEXT, DoubleToString(gPositiveUSD, 2));
   ObjectSetString(0, ObjName("EDIT_NEG"),   OBJPROP_TEXT, FormatNegativeBasketField());
   ObjectSetString(0, ObjName("EDIT_TRAIL_TRIGGER"), OBJPROP_TEXT, DoubleToString(gTrailTriggerUSD, 2));
   ObjectSetString(0, ObjName("EDIT_TRAIL"), OBJPROP_TEXT, DoubleToString(gTrailDistanceUSD, 2));
}
//+------------------------------------------------------------------+
void ReadPanelValues(const bool normalize_fields = false)
{
   if(!gPanelCreated || gBackgroundCheck)
      return;

   string txt;

   txt = TrimString(ObjectGetString(0, ObjName("EDIT_POS"), OBJPROP_TEXT));
   if(txt != "")
   {
      double v = StringToDouble(txt);
      if(v >= 0.0)
         gPositiveUSD = v;
   }

   txt = TrimString(ObjectGetString(0, ObjName("EDIT_NEG"), OBJPROP_TEXT));
   if(txt != "")
   {
      double v = 0.0;
      bool requestedProfitLock = false;
      if(ParseSignedBasketLimit(txt, v, requestedProfitLock))
      {
         bool settingChanged = (MathAbs(v - gNegativeUSD) > 0.0000001 ||
                                requestedProfitLock != gNegativeProfitLock);
         gNegativeUSD = v;
         gNegativeProfitLock = requestedProfitLock;
         if(settingChanged)
            ResetBasketSLState();
      }
      else if(normalize_fields)
      {
         Print("Basket SL ignored. Use an explicit sign: -1000 for a loss limit or +1000 for a protected-profit floor.");
      }
   }

   txt = TrimString(ObjectGetString(0, ObjName("EDIT_TRAIL_TRIGGER"), OBJPROP_TEXT));
   if(txt != "")
   {
      double v = StringToDouble(txt);
      if(v >= 0.0)
      {
         bool settingChanged = (MathAbs(v - gTrailTriggerUSD) > 0.0000001);
         gTrailTriggerUSD = v;
         if(settingChanged)
            ResetProfitTrailState();
      }
   }

   txt = TrimString(ObjectGetString(0, ObjName("EDIT_TRAIL"), OBJPROP_TEXT));
   if(txt != "")
   {
      double v = StringToDouble(txt);
      if(v >= 0.0)
      {
         bool settingChanged = (MathAbs(v - gTrailDistanceUSD) > 0.0000001);
         gTrailDistanceUSD = v;
         if(settingChanged)
            ResetProfitTrailState();
      }
   }

   if(normalize_fields)
      SyncPanelFields();
}
//+------------------------------------------------------------------+
bool CreateLabel(const string name,
                 const string text,
                 const int x,
                 const int y,
                 const int w,
                 const int h,
                 const color clr,
                 const int fontSize = 10)
{
   if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
      return false;

   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);

   return true;
}
//+------------------------------------------------------------------+
bool CreateEdit(const string name,
                const string text,
                const int x,
                const int y,
                const int w,
                const int h)
{
   if(!ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0))
      return false;

   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrSilver);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_ALIGN, ALIGN_RIGHT);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);

   return true;
}
//+------------------------------------------------------------------+
bool CreateButton(const string name,
                  const string text,
                  const int x,
                  const int y,
                  const int w,
                  const int h,
                  const color bg,
                  const color fg)
{
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
      return false;

   ObjectSetInteger(0, name, OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);

   return true;
}
//+------------------------------------------------------------------+
bool CreatePanel()
{
   const int x = InpPanelX;
   const int y = InpPanelY;
   const int w = 750;
   const int h = 620;

   if(!ObjectCreate(0, ObjName("BG"), OBJ_RECTANGLE_LABEL, 0, 0, 0))
      return false;

   ObjectSetInteger(0, ObjName("BG"), OBJPROP_CORNER, InpPanelCorner);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_XSIZE, w);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_YSIZE, h);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_BGCOLOR, clrGainsboro);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_BORDER_COLOR, clrGray);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_COLOR, clrGray);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_BACK, false);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, ObjName("BG"), OBJPROP_HIDDEN, true);

   CreateLabel(ObjName("TITLE"),    "Basket Commander PRO MT5 v1.00",     x + 12, y + 10, 416, 20, clrBlack, 11);
   CreateLabel(ObjName("LBL_POS"),  "Basket TP (account CCY; 0 = off)",      x + 12, y + 45, 260, 18, clrBlack);
   CreateLabel(ObjName("LBL_NEG"),  "Basket SL (-loss / +profit; 0 = off)", x + 12, y + 75, 260, 18, clrBlack);
   CreateLabel(ObjName("LBL_TRAIL_TRIGGER"), "Trail trigger (CCY; 0 = off)", x + 12, y + 105,260, 18, clrBlack);
   CreateLabel(ObjName("LBL_TRAIL"),"Trail distance (CCY; 0 = off)",  x + 12, y + 135,260, 18, clrBlack);

   CreateEdit(ObjName("EDIT_POS"),  DoubleToString(gPositiveUSD, 2),  x + 275, y + 40, 135, 22);
   CreateEdit(ObjName("EDIT_NEG"),  FormatNegativeBasketField(),      x + 275, y + 70, 135, 22);
   CreateEdit(ObjName("EDIT_TRAIL_TRIGGER"), DoubleToString(gTrailTriggerUSD, 2), x + 275, y + 100,135, 22);
   CreateEdit(ObjName("EDIT_TRAIL"),DoubleToString(gTrailDistanceUSD, 2), x + 275, y + 130,135, 22);

   CreateButton(ObjName("BTN_BREAKEVEN"), "BREAKEVEN: OFF", x + 12,  y + 211, 200, 36, clrDimGray, clrWhite);
   CreateButton(ObjName("BTN_HALF"),      "CLOSE 50%",     x + 12, y + 168, 200, 36, clrDarkOrange, clrWhite);
   ObjectSetString(0, ObjName("BTN_HALF"), OBJPROP_TOOLTIP,
                   "Close half of each current-symbol position; round down to lot step. Minimum lots are skipped. Basket exits remain active.");
   CreateButton(ObjName("BTN_HALF_BE"), "CLOSE 50% + BE", x + 220, y + 168, 208, 36, clrSteelBlue, clrWhite);
   CreateButton(ObjName("BTN_CLOSE"), "CLOSE BASKET", x + 220, y + 211, 208, 36, clrRed, clrWhite);
   CreateButton(ObjName("BTN_MODE"), "MODE: COMBINED", x + 12, y + 254, 200, 36, clrDimGray, clrWhite);
   CreateButton(ObjName("BTN_BUY"), "BUY", x + 220, y + 254, 100, 36, clrDimGray, clrWhite);
   CreateButton(ObjName("BTN_SELL"), "SELL", x + 328, y + 254, 100, 36, clrDimGray, clrWhite);
   CreateLabel(ObjName("SCOPE"), "", x + 12, y + 294, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("LEDGER"), "", x + 12, y + 578, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("LEDGER_LAST"), "", x + 12, y + 596, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS_HALF"), "", x + 12, y + 554, 416, 16, clrBlack, 9);

   CreateLabel(ObjName("STATUS1"),  "", x + 12, y + 310, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS2"),  "", x + 12, y + 326, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS3"),  "", x + 12, y + 342, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS4"),  "", x + 12, y + 358, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS5"),  "", x + 12, y + 374, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS6"),  "", x + 12, y + 390, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS7"),  "", x + 12, y + 406, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS8"),  "", x + 12, y + 422, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS9"),  "", x + 12, y + 438, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS10"), "", x + 12, y + 454, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS11"), "", x + 12, y + 470, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS12"), "", x + 12, y + 486, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS13"), "", x + 12, y + 502, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS14"), "", x + 12, y + 518, 416, 16, clrBlack, 9);
   CreateLabel(ObjName("STATUS15"), "", x + 12, y + 534, 416, 16, clrBlack, 9);


   CreateLabel(ObjName("EQ_TITLE"),"ACCOUNT EQUITY - ALL TRADES",x+452,y+12,286,20,clrBlack,10);
   CreateLabel(ObjName("EQ_BALANCE"),"",x+452,y+45,286,18,clrBlack,10);
   CreateLabel(ObjName("EQ_CURRENT"),"",x+452,y+70,286,18,clrBlack,10);
   CreateLabel(ObjName("EQ_TP_LABEL"),"Equity TP",x+452,y+112,120,18,clrDarkGreen,10);
   CreateEdit(ObjName("EDIT_EQTP"),DoubleToString(gAccountTP,2),x+580,y+108,155,24);
   CreateLabel(ObjName("EQ_SL_LABEL"),"Equity SL",x+452,y+148,120,18,clrRed,10);
   CreateEdit(ObjName("EDIT_EQSL"),DoubleToString(gAccountSL,2),x+580,y+144,155,24);
   CreateLabel(ObjName("EQ_HELP"),"Absolute account CCY; 0 = OFF",x+452,y+184,286,18,clrBlack,9);
   CreateLabel(ObjName("EQ_HELP2"),"Press Enter to apply each field",x+452,y+207,286,18,clrBlack,9);
   CreateLabel(ObjName("EQ_HELP3"),"Closes all symbols + pending orders",x+452,y+230,286,18,clrBlack,9);
   CreateLabel(ObjName("EQ_STATUS"),"",x+452,y+265,286,18,clrBlack,9);

   CreateLabel(ObjName("MANAGE_TITLE"),"MANUAL CLOSE SCOPE",x+452,y+300,286,18,clrBlack,9);
   CreateButton(ObjName("BTN_MANAGE_SYMBOL"),"MANAGE SYMBOL BASKET",x+452,y+325,286,36,clrForestGreen,clrWhite);
   CreateButton(ObjName("BTN_MANAGE_WHOLE"),"MANAGE WHOLE BASKET",x+452,y+369,286,36,clrDimGray,clrWhite);
   ObjectSetInteger(0, ObjName("BTN_MANAGE_SYMBOL"), OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, ObjName("BTN_MANAGE_WHOLE"), OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, ObjName("BTN_MANAGE_SYMBOL"), OBJPROP_TOOLTIP,
                   "Manual CLOSE BASKET affects only the current chart symbol. Automatic TP/SL/trailing remain symbol-specific.");
   ObjectSetString(0, ObjName("BTN_MANAGE_WHOLE"), OBJPROP_TOOLTIP,
                   "Manual CLOSE BASKET affects matching positions on all symbols. Magic and BUY/SELL scope are still respected.");
   return true;
}
//+------------------------------------------------------------------+
void DeletePanel()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, PREFIX) == 0)
         ObjectDelete(0, name);
   }
}
//+------------------------------------------------------------------+
double CurrentSymbolFloatingProfit()
{
   double basket = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(!SelectedPositionMatches(gScope))
         continue;

      basket += PositionGetDouble(POSITION_PROFIT)
                + PositionGetDouble(POSITION_SWAP);
   }

   return basket;
}
//+------------------------------------------------------------------+
int CurrentSymbolPositionCount()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(SelectedPositionMatches(gScope))
         count++;
   }

   return count;
}
//+------------------------------------------------------------------+
datetime StartOfServerDay()
{
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();

   MqlDateTime dt;
   TimeToStruct(now, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;

   return StructToTime(dt);
}
//+------------------------------------------------------------------+
void GetCurrentSymbolStats(int &buyCount,
                           int &sellCount,
                           double &buyLots,
                           double &sellLots,
                           double &buyAverageOpen,
                           double &sellAverageOpen,
                           double &totalSwap,
                           double &bestPositionPL,
                           double &worstPositionPL,
                           datetime &oldestPositionTime)
{
   buyCount = 0;
   sellCount = 0;
   buyLots = 0.0;
   sellLots = 0.0;
   buyAverageOpen = 0.0;
   sellAverageOpen = 0.0;
   totalSwap = 0.0;
   bestPositionPL = 0.0;
   worstPositionPL = 0.0;
   oldestPositionTime = 0;

   double buyPriceVolume = 0.0;
   double sellPriceVolume = 0.0;
   bool firstPosition = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(!SelectedPositionMatches(gScope))
         continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double positionPL = PositionGetDouble(POSITION_PROFIT);
      datetime positionTime = (datetime)PositionGetInteger(POSITION_TIME);

      totalSwap += PositionGetDouble(POSITION_SWAP);

      if(firstPosition)
      {
         bestPositionPL = positionPL;
         worstPositionPL = positionPL;
         oldestPositionTime = positionTime;
         firstPosition = false;
      }
      else
      {
         if(positionPL > bestPositionPL)
            bestPositionPL = positionPL;
         if(positionPL < worstPositionPL)
            worstPositionPL = positionPL;
         if(positionTime < oldestPositionTime)
            oldestPositionTime = positionTime;
      }

      if(posType == POSITION_TYPE_BUY)
      {
         buyCount++;
         buyLots += volume;
         buyPriceVolume += openPrice * volume;
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         sellCount++;
         sellLots += volume;
         sellPriceVolume += openPrice * volume;
      }
   }

   if(buyLots > 0.0)
      buyAverageOpen = buyPriceVolume / buyLots;
   if(sellLots > 0.0)
      sellAverageOpen = sellPriceVolume / sellLots;
}
//+------------------------------------------------------------------+
string FormatPositionAge(const datetime oldestPositionTime)
{
   if(oldestPositionTime <= 0)
      return "-";

   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();

   long totalSeconds = (long)(now - oldestPositionTime);
   if(totalSeconds < 0)
      totalSeconds = 0;

   int days = (int)(totalSeconds / 86400);
   int hours = (int)((totalSeconds % 86400) / 3600);
   int minutes = (int)((totalSeconds % 3600) / 60);

   if(days > 0)
      return IntegerToString(days) + "d " + IntegerToString(hours) + "h " + IntegerToString(minutes) + "m";
   if(hours > 0)
      return IntegerToString(hours) + "h " + IntegerToString(minutes) + "m";
   if(minutes > 0)
      return IntegerToString(minutes) + "m";

   return "<1m";
}
//+------------------------------------------------------------------+
void UpdatePanelStatus()
{
   if(gPanelCreated)
   {
      string ccy=AccountInfoString(ACCOUNT_CURRENCY);
      ObjectSetString(0,ObjName("EQ_BALANCE"),OBJPROP_TEXT,"Balance: "+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+" "+ccy);
      ObjectSetString(0,ObjName("EQ_CURRENT"),OBJPROP_TEXT,"Equity: "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+" "+ccy);
      ObjectSetString(0,ObjName("EQ_STATUS"),OBJPROP_TEXT,gAccountClosing ? "CLOSING ALL / retry until flat" : ((gAccountTP>0 || gAccountSL>0) ? "Account limits: ACTIVE" : "Account limits: OFF"));
   }
   ReadPanelValues(false);
   CaptureScope();
   SavePersistentSettings();

   if(!gPanelCreated)
      return;

   UpdateBreakevenButton();

   double basket = CurrentSymbolBasketProfit();
   int    buyCount = 0;
   int    sellCount = 0;
   double buyLots = 0.0;
   double sellLots = 0.0;
   double buyAverageOpen = 0.0;
   double sellAverageOpen = 0.0;
   double totalSwap = 0.0;
   double bestPositionPL = 0.0;
   double worstPositionPL = 0.0;
   datetime oldestPositionTime = 0;
   double todayRealizedPL = 0.0;
   double todayOpenedLots = 0.0;
   int    todayOpenedTrades = 0;

   GetCurrentSymbolStats(buyCount, sellCount, buyLots, sellLots,
                         buyAverageOpen, sellAverageOpen, totalSwap,
                         bestPositionPL, worstPositionPL, oldestPositionTime);
   GetTodaySymbolStats(todayRealizedPL, todayOpenedLots, todayOpenedTrades);

   int count = buyCount + sellCount;
   double netLotDiff = buyLots - sellLots;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spreadPoints = (_Point > 0.0 && ask > 0.0 && bid > 0.0)
                         ? (ask - bid) / _Point
                         : 0.0;
   string buyAverageText = (buyLots > 0.0) ? DoubleToString(buyAverageOpen, _Digits) : "-";
   string sellAverageText = (sellLots > 0.0) ? DoubleToString(sellAverageOpen, _Digits) : "-";
   string bestText = (count > 0) ? FormatSignedUSD(bestPositionPL) : "-";
   string worstText = (count > 0) ? FormatSignedUSD(worstPositionPL) : "-";
   string tpText = (gPositiveUSD > 0.0)
                   ? "+" + DoubleToString(gPositiveUSD, 2)
                   : "OFF";
   string slText = (gNegativeUSD > 0.0)
                   ? FormatSignedUSD(SignedBasketLimitUSD())
                   : "OFF";
   string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);

   string s1 = ScopeName() + " " + _Symbol + " | Positions: " + IntegerToString(count) +
               " | Total P/L: " + FormatSignedUSD(basket) + " " + accountCurrency;
   string s2 = "Buy trades: " + IntegerToString(buyCount) +
               " | Buy lots: " + FormatVolume(buyLots);
   string s3 = "Sell trades: " + IntegerToString(sellCount) +
               " | Sell lots: " + FormatVolume(sellLots);
   string s4 = "Lot diff (Buy - Sell): " + FormatVolume(netLotDiff);
   string s5 = "Average open: BUY " + buyAverageText + " | SELL " + sellAverageText;
   string s6 = "Market: Bid " + DoubleToString(bid, _Digits) +
               " | Ask " + DoubleToString(ask, _Digits) +
               " | Spread " + DoubleToString(spreadPoints, 1) + " points";
   string s7 = "Open positions: Best " + bestText + " | Worst " + worstText + " " + accountCurrency;
   string s8 = "Swap: " + FormatSignedUSD(totalSwap) + " " + accountCurrency +
               " | Basket age: " + FormatPositionAge(oldestPositionTime);
   string s9 = "Today realized P/L: " + FormatSignedUSD(todayRealizedPL) + " " + accountCurrency;
   string s10 = "Today opened lots: " + FormatVolume(todayOpenedLots) +
                " | Today trades: " + IntegerToString(todayOpenedTrades);
   string s11 = "Basket TP: " + tpText + " | Basket SL: " + slText;
   if(gNegativeProfitLock && gNegativeUSD > 0.0)
      s11 += " (" + (gBasketSLArmed ? "ARMED" : "WAIT") + ")";

   string s12;
   if(ProfitTrailSettingsValid())
   {
      if(gProfitTrailArmed)
         s12 = "Trail ARMED: peak +" + DoubleToString(gProfitTrailPeakUSD, 2) +
               " | floor " + FormatSignedUSD(ProfitTrailFloorUSD()) +
               " | gap " + DoubleToString(gTrailDistanceUSD, 2);
      else
         s12 = "Trail WAIT: trigger +" + DoubleToString(gTrailTriggerUSD, 2) +
               " | gap " + DoubleToString(gTrailDistanceUSD, 2);
   }
   else
      s12 = "Trail: OFF (trigger and distance must both be above 0)";

   string s13 = "Account: Balance " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) +
                " | Equity " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) +
                " " + accountCurrency;
   string s14 = "Margin: Used " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) +
                " | Free " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) +
                " | Level " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), 1) + "%";
   string s15;
   if(gBreakevenMode == BREAKEVEN_RECOVERY)
      s15 = "Breakeven: RECOVERY | Close target 0.00 " + accountCurrency;
   else if(gBreakevenMode == BREAKEVEN_PROTECT)
      s15 = "Breakeven: PROTECT | Protected floor 0.00 " + accountCurrency;
   else
      s15 = "Breakeven: OFF";

   ObjectSetString(0, ObjName("STATUS1"), OBJPROP_TEXT, s1);
   ObjectSetString(0, ObjName("STATUS2"), OBJPROP_TEXT, s2);
   ObjectSetString(0, ObjName("STATUS3"), OBJPROP_TEXT, s3);
   ObjectSetString(0, ObjName("STATUS4"), OBJPROP_TEXT, s4);
   ObjectSetString(0, ObjName("STATUS5"), OBJPROP_TEXT, s5);
   ObjectSetString(0, ObjName("STATUS6"), OBJPROP_TEXT, s6);
   ObjectSetString(0, ObjName("STATUS7"), OBJPROP_TEXT, s7);
   ObjectSetString(0, ObjName("STATUS8"), OBJPROP_TEXT, s8);
   ObjectSetString(0, ObjName("STATUS9"), OBJPROP_TEXT, s9);
   ObjectSetString(0, ObjName("STATUS10"), OBJPROP_TEXT, s10);
   ObjectSetString(0, ObjName("STATUS11"), OBJPROP_TEXT, s11);
   ObjectSetString(0, ObjName("STATUS12"), OBJPROP_TEXT, s12);
   ObjectSetString(0, ObjName("STATUS13"), OBJPROP_TEXT, s13);
   ObjectSetString(0, ObjName("STATUS14"), OBJPROP_TEXT, s14);
   ObjectSetString(0, ObjName("STATUS15"), OBJPROP_TEXT, s15);
   ObjectSetString(0, ObjName("STATUS_HALF"), OBJPROP_TEXT, gHalfCloseStatus);

   ObjectSetString(0, ObjName("BTN_MODE"), OBJPROP_TEXT, gSplit ? "MODE: SPLIT" : "MODE: COMBINED");
   ObjectSetInteger(0, ObjName("BTN_BUY"), OBJPROP_BGCOLOR, gScope == 1 ? clrForestGreen : clrDimGray);
   ObjectSetInteger(0, ObjName("BTN_SELL"), OBJPROP_BGCOLOR, gScope == 2 ? clrFireBrick : clrDimGray);
   ObjectSetInteger(0, ObjName("BTN_MANAGE_SYMBOL"), OBJPROP_BGCOLOR, gManageWholeBasket ? clrDimGray : clrForestGreen);
   ObjectSetInteger(0, ObjName("BTN_MANAGE_WHOLE"), OBJPROP_BGCOLOR, gManageWholeBasket ? clrFireBrick : clrDimGray);
   ObjectSetString(0, ObjName("BTN_CLOSE"), OBJPROP_TEXT, gManageWholeBasket ? "CLOSE WHOLE BASKET" : "CLOSE SYMBOL BASKET");
   ObjectSetInteger(0, ObjName("BTN_CLOSE"), OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, ObjName("SCOPE"), OBJPROP_TEXT, ScopeName() + " | Magic " + (InpMagicNumber < 0 ? "ALL" : IntegerToString(InpMagicNumber)) + " | Manual: " + ManageModeName());
   ObjectSetString(0, ObjName("LEDGER"), OBJPROP_TEXT,
      "Realized " + FormatSignedUSD(gLedger[gScope].realized) + " | Floating " + FormatSignedUSD(CurrentSymbolFloatingProfit()));
   ObjectSetString(0, ObjName("LEDGER_LAST"), OBJPROP_TEXT,
      (gLedger[gScope].ready ? "History OK | Last cycle " : "HISTORY NOT READY - exits paused | Last ") + FormatSignedUSD(gLedger[gScope].lastResult));
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
// Return a legal reduction no larger than half; never fully close a ticket.
double HalfCloseVolume(const double volume, const double minimum, const double step)
{
   if(volume <= 0.0 || minimum <= 0.0 || step <= 0.0)
      return 0.0;
   double amount = NormalizeDouble(MathFloor(volume * 0.5 / step + 1e-9) * step,
                                   DigitsFromStep(step));
   double epsilon = step * 1e-7;
   if(amount < minimum - epsilon || volume - amount < minimum - epsilon ||
      amount > volume * 0.5 + epsilon || amount >= volume - epsilon)
      return 0.0;
   return amount;
}
//+------------------------------------------------------------------+
void CloseHalfSymbolPositions()
{
   gLastHalfFilled = 0.0;
   ulong now = GetTickCount64();
   if(gHalfCloseBusy || (gHalfCloseFinishedMs != 0 && now - gHalfCloseFinishedMs < 1500))
      return; // Ignore a queued double-click, including during slow execution.
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      gHalfCloseStatus = "50%: trading disabled; no requests sent";
      Print(gHalfCloseStatus);
      return;
   }

   gHalfCloseBusy = true;
   ObjectSetString(0, ObjName("BTN_HALF"), OBJPROP_TEXT, "...");
   ChartRedraw(0);

   // Snapshot tickets, identifiers and volumes so newly opened positions are excluded.
   ulong tickets[];
   long identifiers[];
   double volumes[];
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !SelectedPositionMatches(gScope))
         continue;
      ArrayResize(tickets, count + 1);
      ArrayResize(identifiers, count + 1);
      ArrayResize(volumes, count + 1);
      tickets[count] = ticket;
      identifiers[count] = PositionGetInteger(POSITION_IDENTIFIER);
      volumes[count] = PositionGetDouble(POSITION_VOLUME);
      count++;
   }

   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   int skipped = 0, failed = 0, completed = 0;
   double confirmedLots = 0.0;
   bool uncertain = false;
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   for(int i = 0; i < count; i++)
   {
      double amount = HalfCloseVolume(volumes[i], minimum, step);
      if(amount <= 0.0)
      {
         skipped++;
         Print("50% skipped ticket ", tickets[i], ": minimum volume/lot step prevents halving.");
         continue;
      }
      // Oversized orders are explicitly skipped, never silently capped or retried.
      if(maximum <= 0.0 || amount > maximum + step * 1e-7 ||
         ((filling & SYMBOL_FILLING_FOK) == 0 && (filling & SYMBOL_FILLING_IOC) == 0))
      {
         failed++;
         Print("50% skipped ticket ", tickets[i], ": unsupported immediate filling or request exceeds maximum deal volume.");
         continue;
      }
      if(!PositionSelectByTicket(tickets[i]) ||
         PositionGetInteger(POSITION_IDENTIFIER) != identifiers[i] ||
         !SelectedPositionMatches(gScope) ||
         MathAbs(PositionGetDouble(POSITION_VOLUME) - volumes[i]) > step * 1e-7)
      {
         skipped++;
         Print("50% skipped changed/missing position ", tickets[i]);
         continue;
      }

      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      MqlTick tick = {};
      if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      {
         failed++;
         continue;
      }
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      request.action = TRADE_ACTION_DEAL;
      request.position = tickets[i]; // Explicit ticket for both hedging and netting.
      request.symbol = _Symbol;
      request.magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      request.volume = amount;
      request.type = isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = isBuy ? tick.bid : tick.ask;
      request.deviation = (ulong)MathMax(0, InpSlippagePoints);
      request.type_filling = ((filling & SYMBOL_FILLING_FOK) != 0)
                            ? ORDER_FILLING_FOK : ORDER_FILLING_IOC;
      request.comment = "Basket Commander 50%";
      bool sent = OrderSend(request, result);
      Print("50% ticket ", tickets[i], " requested=", DoubleToString(amount, VolumeDigits()),
            " sent=", sent, " retcode=", result.retcode,
            " filled=", DoubleToString(result.volume, VolumeDigits()), " ", result.comment);
      if(sent && (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL))
      {
         confirmedLots += result.volume;
         completed++;
      }
      else
      {
         failed++;
         if(result.retcode == TRADE_RETCODE_PLACED || result.retcode == TRADE_RETCODE_TIMEOUT)
         {
            uncertain = true;
            Print("50% execution unresolved; stopped without retry. Inspect account and Experts log.");
            break;
         }
      }
   }
   gLastHalfFilled = confirmedLots;
   gHistoryDirty = true;
   RefreshAccounting(true);
   gHalfCloseStatus = "50%: filled " + FormatVolume(confirmedLots) + " lots; skip " +
                     IntegerToString(skipped) + "; errors " + IntegerToString(failed);
   if(count == 0)
      gHalfCloseStatus = "50%: no open positions on " + _Symbol;
   if(uncertain)
      gHalfCloseStatus = "50%: execution unresolved - check Experts log";
   Print(gHalfCloseStatus, "; confirmed requests=", completed,
         ". Basket exits remain active on total cycle P/L.");
   gHalfCloseFinishedMs = GetTickCount64();
   gHalfCloseBusy = false;
   ObjectSetString(0, ObjName("BTN_HALF"), OBJPROP_TEXT, "CLOSE 50%");
}
//+------------------------------------------------------------------+
void CloseAllSymbolPositions(const string symbol)
{
   gClosingScope[gScope] = true;
   ulong now = GetTickCount64();
   if(gLastCloseAttempt[gScope] != 0 && now - gLastCloseAttempt[gScope] < 1000) return;
   gLastCloseAttempt[gScope] = now;
   double basketAtClose = CurrentSymbolBasketProfit();
   int attemptedCount   = CurrentSymbolPositionCount();
   int closedCount      = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol || !SelectedPositionMatches(gScope))
         continue;

      trade.SetTypeFillingBySymbol(_Symbol);
      if(trade.PositionClose(ticket) && trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         closedCount++;
      }
      else
      {
         Print("Failed to close ticket ", ticket,
               ". Retcode=", trade.ResultRetcode(),
               " Description=", trade.ResultRetcodeDescription());
      }
   }

   gHistoryDirty = true;
   string closeMessage = "Basket close executed on " + symbol + " " + ScopeName() +
                         ". Basket P/L at close trigger: " + DoubleToString(basketAtClose, 2) + " USD" +
                         ". Positions requested: " + IntegerToString(attemptedCount) +
                         ". Positions closed: " + IntegerToString(closedCount);

   Print(closeMessage);
   Alert(closeMessage);
}
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(!SelectedOrderMatches())
         continue;

      if(!trade.OrderDelete(ticket))
      {
         Print("Failed to delete order ", ticket,
               ". Retcode=", trade.ResultRetcode(),
               " Description=", trade.ResultRetcodeDescription());
      }
   }
}
//+------------------------------------------------------------------+
void ToggleBreakeven()
{
   if(gBreakevenMode != BREAKEVEN_OFF)
   {
      ResetBreakevenState();
      Print("Basket breakeven switched OFF on ", _Symbol, ".");
      return;
   }

   if(CurrentSymbolPositionCount() == 0)
   {
      Print("Basket breakeven was not armed because there are no open positions on ", _Symbol, ".");
      return;
   }

   double basket = CurrentSymbolBasketProfit();
   if(basket < BREAKEVEN_LEVEL_USD)
   {
      gBreakevenMode = BREAKEVEN_RECOVERY;
      Print("Basket breakeven RECOVERY armed on ", _Symbol,
            ". Current basket P/L=", DoubleToString(basket, 2),
            ". Close target=", DoubleToString(BREAKEVEN_LEVEL_USD, 2), ".");
   }
   else
   {
      gBreakevenMode = BREAKEVEN_PROTECT;
      Print("Basket breakeven PROTECT armed on ", _Symbol,
            ". Current basket P/L=", DoubleToString(basket, 2),
            ". Protected floor=", DoubleToString(BREAKEVEN_LEVEL_USD, 2), ".");
   }
}
//+------------------------------------------------------------------+
void CloseWholeManualBasket()
{
   int attemptedCount = ManagedPositionCount();
   int closedCount = 0;
   int orderDeleted = 0;
   int failures = 0;
   double floatingAtRequest = ManagedFloatingProfit();

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !SelectedOrderMatchesManual()) continue;
      if(trade.OrderDelete(ticket) && trade.ResultRetcode() == TRADE_RETCODE_DONE) orderDeleted++;
      else
      {
         failures++;
         Print("Whole basket: failed to delete order ", ticket,
               ". Retcode=", trade.ResultRetcode(),
               " Description=", trade.ResultRetcodeDescription());
      }
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket) || !SelectedPositionMatchesManual(gScope)) continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      if(!trade.SetTypeFillingBySymbol(symbol))
      {
         failures++;
         Print("Whole basket: unsupported filling mode on ", symbol, " ticket ", ticket);
         continue;
      }
      if(trade.PositionClose(ticket) && trade.ResultRetcode() == TRADE_RETCODE_DONE) closedCount++;
      else
      {
         failures++;
         Print("Whole basket: failed to close ticket ", ticket, " ", symbol,
               ". Retcode=", trade.ResultRetcode(),
               " Description=", trade.ResultRetcodeDescription());
      }
   }

   gHistoryDirty = true;
   string msg = "Manual whole-basket close: " + ScopeName() +
                " | Magic " + (InpMagicNumber < 0 ? "ALL" : IntegerToString(InpMagicNumber)) +
                " | Floating P/L at request " + DoubleToString(floatingAtRequest, 2) + " " +
                AccountInfoString(ACCOUNT_CURRENCY) +
                " | Positions " + IntegerToString(closedCount) + "/" + IntegerToString(attemptedCount) +
                " | Pending deleted " + IntegerToString(orderDeleted) +
                " | Errors " + IntegerToString(failures);
   gHalfCloseStatus = msg;
   Print(msg);
   Alert(msg);
}

void CloseAllNow()
{
   if(gManageWholeBasket)
      CloseWholeManualBasket();
   else
   {
      CloseAllSymbolPositions(_Symbol);
      DeleteAllPendingOrders();
   }

   gHistoryDirty = true;
   RefreshAccounting(true);
   if(CurrentSymbolPositionCount() == 0)
   {
      ResetProfitTrailState();
      ResetBasketSLState();
      ResetBreakevenState();
   }
}
//+------------------------------------------------------------------+
void CheckEquityExit()
{
   if(gClosingScope[gScope])
   {
      if(CurrentSymbolPositionCount() > 0) CloseAllSymbolPositions(_Symbol);
      else gClosingScope[gScope] = false;
      return;
   }
   if(!gLedger[gScope].ready) return;
   int count = CurrentSymbolPositionCount();
   if(count == 0)
   {
      ResetProfitTrailState();
      ResetBasketSLState();
      ResetBreakevenState();
      return;
   }

   ReadPanelValues(false);

   double basket = CurrentSymbolBasketProfit();

   // Basket TP has absolute priority. If TP equals the trail trigger,
   // the basket closes here and trailing is never armed.
   if(gPositiveUSD > 0.0 && basket >= gPositiveUSD)
   {
      Print("Basket TP hit on ", _Symbol,
            ". Basket P/L=", DoubleToString(basket, 2),
            " USD, Basket TP=+", DoubleToString(gPositiveUSD, 2), " USD.");
      CloseAllSymbolPositions(_Symbol);
      if(CurrentSymbolPositionCount() == 0)
      {
         ResetProfitTrailState();
         ResetBasketSLState();
         ResetBreakevenState();
      }
      return;
   }

   bool hitBasketSL = false;
   if(gNegativeProfitLock)
   {
      if(gNegativeUSD <= 0.0)
      {
         ResetBasketSLState();
      }
      else
      {
         if(!gBasketSLArmed && basket > gNegativeUSD)
         {
            gBasketSLArmed = true;
            Print("Positive Basket SL armed on ", _Symbol,
                  ". Basket P/L=", DoubleToString(basket, 2),
                  " USD, protected floor=+", DoubleToString(gNegativeUSD, 2), " USD.");
         }

         hitBasketSL = (gBasketSLArmed && basket <= gNegativeUSD);
      }
   }
   else
   {
      ResetBasketSLState();
      hitBasketSL = (gNegativeUSD > 0.0 && basket <= -gNegativeUSD);
   }

   if(hitBasketSL)
   {
      string slReason = gNegativeProfitLock ? "positive protected-profit floor" : "negative loss limit";
      Print("Basket SL hit on ", _Symbol,
            ". Reason=", slReason,
            ". Basket P/L=", DoubleToString(basket, 2),
            " USD, Basket SL=", FormatSignedUSD(SignedBasketLimitUSD()), " USD.");
      CloseAllSymbolPositions(_Symbol);
      if(CurrentSymbolPositionCount() == 0)
      {
         ResetProfitTrailState();
         ResetBasketSLState();
         ResetBreakevenState();
      }
      return;
   }

   bool hitBreakeven = ((gBreakevenMode == BREAKEVEN_RECOVERY && basket >= BREAKEVEN_LEVEL_USD) ||
                        (gBreakevenMode == BREAKEVEN_PROTECT && basket <= BREAKEVEN_LEVEL_USD));
   if(hitBreakeven)
   {
      string breakevenReason = (gBreakevenMode == BREAKEVEN_RECOVERY)
                               ? "recovery target"
                               : "protected floor";
      Print("Basket breakeven hit on ", _Symbol,
            ". Reason=", breakevenReason,
            ". Basket P/L=", DoubleToString(basket, 2), " USD.");
      CloseAllSymbolPositions(_Symbol);
      if(CurrentSymbolPositionCount() == 0)
      {
         ResetProfitTrailState();
         ResetBasketSLState();
         ResetBreakevenState();
      }
      return;
   }

   if(!ProfitTrailSettingsValid())
   {
      ResetProfitTrailState();
      return;
   }

   if(!gProfitTrailArmed && basket >= gTrailTriggerUSD)
   {
      gProfitTrailArmed = true;
      gProfitTrailPeakUSD = basket;
      Print("Basket profit trailing armed on ", _Symbol,
            ". Trigger=+", DoubleToString(gTrailTriggerUSD, 2),
            " USD, basket P/L=+", DoubleToString(basket, 2),
            " USD, protected floor=", FormatSignedUSD(ProfitTrailFloorUSD()),
            " USD, trailing distance=", DoubleToString(gTrailDistanceUSD, 2), " USD.");
   }

   if(!gProfitTrailArmed)
      return;

   if(basket > gProfitTrailPeakUSD)
      gProfitTrailPeakUSD = basket;

   if(basket <= ProfitTrailFloorUSD())
   {
      Print("Basket trailing floor hit on ", _Symbol,
            ". Basket P/L=", DoubleToString(basket, 2),
            " USD, trail floor=", FormatSignedUSD(ProfitTrailFloorUSD()), " USD.");
      CloseAllSymbolPositions(_Symbol);
      if(CurrentSymbolPositionCount() == 0)
      {
         ResetProfitTrailState();
         ResetBasketSLState();
         ResetBreakevenState();
      }
   }
}
// State is isolated by account, server, symbol and magic filter.
string BuildStateKey()
{
   string identity = AccountInfoString(ACCOUNT_SERVER) + "|" +
                     IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "|" +
                     _Symbol + "|" + IntegerToString(InpMagicNumber);
   uint a = 2166136261, b = 5381;
   for(int i = 0; i < StringLen(identity); i++)
   {
      uint c = (uint)StringGetCharacter(identity, i);
      a = (a ^ c) * 16777619;
      b = b * 33 + c;
   }
   return "BC17_" + IntegerToString((long)a) + "_" + IntegerToString((long)b);
}
string LedgerFile(const int scope)
{
   return gStateKey + "_cycle_" + IntegerToString(scope) + ".csv";
}
bool SaveLedger(const int scope)
{
   if(gTesterMode) return true;
   string target = LedgerFile(scope), temp = target + ".tmp";
   int f = FileOpen(temp, FILE_WRITE | FILE_CSV | FILE_ANSI, '\t');
   if(f == INVALID_HANDLE) { Print("Cannot write basket ledger: ", GetLastError()); return false; }
   uint written = FileWrite(f, "BC17", gLedger[scope].ids, DoubleToString(gLedger[scope].lastResult, 8), "END");
   FileFlush(f); FileClose(f);
   if(written == 0 || !FileMove(temp, 0, target, FILE_REWRITE))
   { Print("Cannot commit basket ledger: ", GetLastError()); return false; }
   return true;
}
void LoadLedger(const int scope)
{
   gLedger[scope].ids = "";
   gLedger[scope].realized = 0.0;
   gLedger[scope].lastResult = 0.0;
   gLedger[scope].ready = true;
   if(gTesterMode || !FileIsExist(LedgerFile(scope))) return;
   int f = FileOpen(LedgerFile(scope), FILE_READ | FILE_CSV | FILE_ANSI, '\t');
   if(f == INVALID_HANDLE) { gLedger[scope].ready = false; gLedger[scope].ids = "INVALID"; return; }
   string header = FileReadString(f);
   string ids = FileReadString(f);
   string last = FileReadString(f);
   string end = FileReadString(f);
   FileClose(f);
   if(header != "BC17" || end != "END")
   {
      Print("Invalid ledger file: ", LedgerFile(scope));
      gLedger[scope].ready = false;
      // Do not guess a fresh cycle after corrupt persisted state.
      gLedger[scope].ids = "INVALID";
      return;
   }
   gLedger[scope].ids = ids;
   gLedger[scope].lastResult = StringToDouble(last);
}
bool ContainsPositionId(const string list, const string id)
{
   return StringFind("|" + list + "|", "|" + id + "|") >= 0;
}
double CurrentSymbolBasketProfit()
{
   return gLedger[gScope].realized + CurrentSymbolFloatingProfit();
}
// Sum all deals for cycle position identifiers; manual exits retain attribution.
// Validate signed deal volume against the current position to avoid reacting
// between a volume update and the corresponding history update.
bool ReadCycleRealized(const string ids, double &realized)
{
   realized = 0.0;
   if(ids == "") return true;
   if(ids == "INVALID") return false;
   string parts[];
   int n = StringSplit(ids, '|', parts);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   for(int p = 0; p < n; p++)
   {
      ulong id = (ulong)StringToInteger(parts[p]);
      if(id == 0 || !HistorySelectByPosition(id) || HistoryDealsTotal() == 0) return false;
      double signedVolume = 0.0;
      for(int d = 0; d < HistoryDealsTotal(); d++)
      {
         ulong deal = HistoryDealGetTicket(d);
         if(deal == 0) return false;
         long type = HistoryDealGetInteger(deal, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
         double volume = HistoryDealGetDouble(deal, DEAL_VOLUME);
         signedVolume += (type == DEAL_TYPE_BUY ? volume : -volume);
         realized += HistoryDealGetDouble(deal, DEAL_PROFIT) +
                     HistoryDealGetDouble(deal, DEAL_SWAP) +
                     HistoryDealGetDouble(deal, DEAL_COMMISSION) +
                     HistoryDealGetDouble(deal, DEAL_FEE);
      }
      double openVolume = 0.0;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(PositionGetTicket(i) == 0) continue;
         if((ulong)PositionGetInteger(POSITION_IDENTIFIER) != id) continue;
         openVolume = PositionGetDouble(POSITION_VOLUME) *
                      (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1.0 : -1.0);
         break;
      }
      if(MathAbs(openVolume - signedVolume) > MathMax(step * 0.01, 1e-8)) return false;
   }
   return true;
}
void ResetScopeProtection(const int scope)
{
   gScopes[scope].peak = 0.0;
   gScopes[scope].trailArmed = false;
   gScopes[scope].slArmed = false;
   gScopes[scope].be = BREAKEVEN_OFF;
   gPendingHalfBE[scope] = false;
   gClosingScope[scope] = false;
}
void RefreshAccounting(const bool force = false)
{
   ulong now = GetTickCount64();
   string signature = "";
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) == 0 || !SelectedPositionMatches(0)) continue;
      signature += IntegerToString(PositionGetInteger(POSITION_IDENTIFIER)) + ":" +
                   DoubleToString(PositionGetDouble(POSITION_VOLUME), 8) + ":" +
                   IntegerToString(PositionGetInteger(POSITION_TYPE)) + ";";
   }
   if(!force && !gHistoryDirty && signature == gLiveSignature && now - gLastHistoryMs < 1000) return;
   CaptureScope();
   int view = gScope;
   bool allReady = true;
   for(int scope = 0; scope < 3; scope++)
   {
      if(gLedger[scope].ids == "INVALID") { allReady = false; continue; }
      string openIds = "";
      bool overlap = false;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(PositionGetTicket(i) == 0 || !SelectedPositionMatches(scope)) continue;
         string id = IntegerToString(PositionGetInteger(POSITION_IDENTIFIER));
         if(openIds != "") openIds += "|";
         openIds += id;
         if(ContainsPositionId(gLedger[scope].ids, id)) overlap = true;
      }
      bool changed = false;
      // No shared position means the previous cycle has ended, even if the
      // terminal was offline when a new, unrelated basket started.
      if(gLedger[scope].ids != "" && !overlap)
      {
         double finalPL = 0.0;
         if(!ReadCycleRealized(gLedger[scope].ids, finalPL))
         { gLedger[scope].ready = false; allReady = false; continue; }
         gLedger[scope].lastResult = finalPL;
         gLedger[scope].ids = "";
         gLedger[scope].realized = 0.0;
         ResetScopeProtection(scope);
         changed = true;
      }
      string parts[];
      int n = StringSplit(openIds, '|', parts);
      for(int p = 0; p < n; p++)
      {
         if(parts[p] == "" || ContainsPositionId(gLedger[scope].ids, parts[p])) continue;
         if(gLedger[scope].ids == "") ResetScopeProtection(scope);
         else gLedger[scope].ids += "|";
         gLedger[scope].ids += parts[p];
         changed = true;
      }
      double realized = 0.0;
      gLedger[scope].ready = ReadCycleRealized(gLedger[scope].ids, realized);
      if(gLedger[scope].ready) gLedger[scope].realized = realized;
      if(changed) gLedgerWritePending[scope] = true;
      if(gLedgerWritePending[scope])
      {
         if(SaveLedger(scope)) gLedgerWritePending[scope] = false;
         else gLedger[scope].ready = false;
      }
      if(gPendingHalfBE[scope] && gLedger[scope].ready)
      {
         if(openIds != "")
         {
            ActivateScope(scope);
            gScopes[scope].be = CurrentSymbolBasketProfit() < 0.0 ? BREAKEVEN_RECOVERY : BREAKEVEN_PROTECT;
         }
         gPendingHalfBE[scope] = false;
      }
      if(!gLedger[scope].ready) allReady = false;
   }
   ActivateScope(view);
   if(allReady) gLiveSignature = signature;
   gHistoryDirty = !allReady;
   gLastHistoryMs = now;
}
void SaveAllScopes()
{
   if(gTesterMode) return;
   int view = gScope;
   for(int s = 0; s < 3; s++)
   {
      ActivateScope(s); SavePersistentSettings();
   }
   ActivateScope(view);
   GlobalVariableSet(gStateKey + "_MODE", gSplit ? 1.0 : 0.0);
   GlobalVariableSet(gStateKey + "_MANAGE_WHOLE", gManageWholeBasket ? 1.0 : 0.0);
   GlobalVariablesFlush();
}
void ProcessBaskets()
{
   if(ProcessAccountEquity()) return;
   ReadPanelValues(false);
   CaptureScope();
   RefreshAccounting();
   int view = gScope;
   gBackgroundCheck = true;
   if(gSplit)
   {
      for(int s = 1; s <= 2; s++)
      {
         ActivateScope(s); CheckEquityExit(); CaptureScope(); SavePersistentSettings();
      }
   }
   else
   {
      ActivateScope(0); CheckEquityExit(); CaptureScope(); SavePersistentSettings();
   }
   ActivateScope(view);
   gBackgroundCheck = false;
}
bool SelectedOrderMatches()
{
   if(OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   if(InpMagicNumber >= 0 && OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) return false;
   long type = OrderGetInteger(ORDER_TYPE);
   bool buy = type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT;
   bool sell = type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT;
   return (gScope == 0 && (buy || sell)) || (gScope == 1 && buy) || (gScope == 2 && sell);
}
bool HistoryPositionMatches(const long id)
{
   if(id <= 0 || !HistorySelectByPosition((ulong)id)) return false;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) return false;
      if(InpMagicNumber >= 0 && HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber) return false;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      return gScope == 0 || (gScope == 1 && type == DEAL_TYPE_BUY) || (gScope == 2 && type == DEAL_TYPE_SELL);
   }
   return false;
}
struct DailyDeal
{
   long position, entry;
   double volume, pl;
};
void GetTodaySymbolStats(double &realizedPL, double &openedLots, int &openedTrades)
{
   realizedPL = 0.0; openedLots = 0.0; openedTrades = 0;
   if(!HistorySelect(StartOfServerDay(), TimeCurrent())) return;
   DailyDeal deals[];
   int n = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      ArrayResize(deals, n + 1);
      deals[n].position = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      deals[n].entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      deals[n].volume = HistoryDealGetDouble(d, DEAL_VOLUME);
      deals[n].pl = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                    HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      n++;
   }
   // Snapshot first: HistorySelectByPosition changes the selected history lists.
   for(int i = 0; i < n; i++)
   {
      if(!HistoryPositionMatches(deals[i].position)) continue;
      realizedPL += deals[i].pl;
      if(deals[i].entry == DEAL_ENTRY_IN || deals[i].entry == DEAL_ENTRY_INOUT)
      { openedLots += deals[i].volume; openedTrades++; }
   }
}

//+------------------------------------------------------------------+
//| Expert lifecycle                                                 |
//+------------------------------------------------------------------+

input bool InpIntegrationSelfTest = true;
int gITStep=0, gITPass=0, gITFail=0;
double gITBeforeLots=0.0;

void ITLog(const string msg) { Print("[BC_MT5_TEST] ",msg); }
void ITAssert(const bool ok,const string name)
{
   if(ok){ gITPass++; ITLog("PASS | "+name); }
   else  { gITFail++; ITLog("FAIL | "+name); }
}
double ITLots(const int scope=0)
{
   double lots=0.0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t) || !SelectedPositionMatches(scope)) continue;
      lots+=PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}
int ITPendingCount()
{
   int n=0;
   int view=gScope;
   ActivateScope(0);
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong t=OrderGetTicket(i);
      if(t!=0 && SelectedOrderMatches()) n++;
   }
   ActivateScope(view);
   return n;
}
bool ITOpenBuy(const double lots)
{
   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool ok=trade.Buy(lots,_Symbol,0,0,0,"BC_MT5_TEST");
   if(!ok) ITLog("Buy failed: "+trade.ResultRetcodeDescription());
   gHistoryDirty=true;
   return ok;
}
bool ITOpenSell(const double lots)
{
   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool ok=trade.Sell(lots,_Symbol,0,0,0,"BC_MT5_TEST");
   if(!ok) ITLog("Sell failed: "+trade.ResultRetcodeDescription());
   gHistoryDirty=true;
   return ok;
}
bool ITOpenPending()
{
   MqlTick tick={};
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double dist=MathMax(100.0,(double)stops+20.0)*point;
   double price=NormalizeDouble(tick.ask+dist,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   bool ok=trade.BuyStop(0.01,price,_Symbol,0,0,ORDER_TIME_GTC,0,"BC_MT5_TEST_PENDING");
   if(!ok) ITLog("Pending failed: "+trade.ResultRetcodeDescription());
   return ok;
}
void ITResetProtection()
{
   gPositiveUSD=0; gNegativeUSD=0; gNegativeProfitLock=false;
   gTrailTriggerUSD=0; gTrailDistanceUSD=0;
   ResetProfitTrailState(); ResetBasketSLState(); ResetBreakevenState();
   CaptureScope();
}
void ITCleanup()
{
   int view=gScope;
   gManageWholeBasket=false;
   ActivateScope(0);
   CloseAllNow();
   ActivateScope(view);
}
void ITFinish()
{
   ITCleanup();
   string result="PASS="+IntegerToString(gITPass)+" FAIL="+IntegerToString(gITFail);
   ITLog("COMPLETE | "+result);
   int h=FileOpen("BasketCommander\\MT5_PRO_integration_result.txt",FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h!=INVALID_HANDLE)
   {
      FileWrite(h,result);
      FileWrite(h,"Login="+IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)));
      FileWrite(h,"Server="+AccountInfoString(ACCOUNT_SERVER));
      FileWrite(h,"Symbol="+_Symbol);
      FileWrite(h,"Time="+TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS));
      FileClose(h);
   }
   gITStep=999;
}
void IntegrationSelfTest()
{
   if(!InpIntegrationSelfTest || !gTesterMode || gITStep==999) return;

   if(gITStep==0)
   {
      ITLog("START");
      ITAssert(AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING,
               "tester account is hedging");
      ITCleanup(); ITResetProtection();
      gITStep=1; return;
   }
   if(gITStep==1)
   {
      bool a=ITOpenBuy(0.04), b=ITOpenSell(0.04);
      if(!a || !b)
      {
         // Broker session may still be closed around midnight. This is not
         // a Basket Commander failure; clean any partial attempt and retry
         // on the next generated tick until market orders are accepted.
         gLastCloseAttempt[0]=0;
         ITCleanup();
         return;
      }
      ITAssert(true,"open BUY+SELL 0.04");
      gITStep=2; return;
   }
   if(gITStep==2)
   {
      RefreshAccounting(true);
      ITAssert(CurrentSymbolPositionCount()==2,"position count before CLOSE 50%");
      gITBeforeLots=ITLots(0);
      gHalfCloseFinishedMs=0;
      CloseHalfSymbolPositions();
      gITStep=3; return;
   }
   if(gITStep==3)
   {
      double after=ITLots(0);
      if(!(gITBeforeLots>0 && after>0 && after<gITBeforeLots)) return;
      ITAssert(MathAbs(after-gITBeforeLots/2.0)<0.021,"CLOSE 50% volume");
      if(!ITOpenPending()) return;
      ITAssert(true,"open pending order");
      gITStep=4; return;
   }
   if(gITStep==4)
   {
      ITAssert(ITPendingCount()>0,"pending order visible");
      gManageWholeBasket=false; ActivateScope(0); gLastCloseAttempt[0]=0; CloseAllNow();
      gITStep=5; return;
   }
   if(gITStep==5)
   {
      ITAssert(CurrentSymbolPositionCount()==0,"CLOSE BASKET positions");
      ITAssert(ITPendingCount()==0,"CLOSE BASKET pending deletion");
      ITAssert(ITOpenBuy(0.02),"open trade for Basket TP/SL");
      gITStep=6; return;
   }
   if(gITStep==6)
   {
      ActivateScope(0); RefreshAccounting(true);
      if(!gLedger[0].ready){ gHistoryDirty=true; return; }
      double pl=CurrentSymbolBasketProfit();
      gPositiveUSD=0; gNegativeUSD=0; gNegativeProfitLock=false;
      if(pl>=0.01) gPositiveUSD=MathMax(0.005,pl*0.5);
      else gNegativeUSD=MathMax(0.005,(-pl)*0.5);
      gLastCloseAttempt[0]=0; CheckEquityExit();
      gITStep=7; return;
   }
   if(gITStep==7)
   {
      if(CurrentSymbolPositionCount()>0)
      {
         ActivateScope(0); CheckEquityExit(); return;
      }
      ITAssert(true,"Basket TP/SL trigger closes basket");
      ITResetProtection();
      if(!ITOpenBuy(0.02)) return;
      ITAssert(true,"open trade for breakeven");
      gITStep=8; return;
   }
   if(gITStep==8)
   {
      ActivateScope(0); RefreshAccounting(true);
      if(!gLedger[0].ready){ gHistoryDirty=true; return; }
      double pl=CurrentSymbolBasketProfit();
      gBreakevenMode=(pl<=0 ? BREAKEVEN_PROTECT : BREAKEVEN_RECOVERY);
      gLastCloseAttempt[0]=0; CheckEquityExit();
      gITStep=9; return;
   }
   if(gITStep==9)
   {
      if(CurrentSymbolPositionCount()>0)
      {
         ActivateScope(0); CheckEquityExit(); return;
      }
      ITAssert(true,"Breakeven exit branch");
      ITResetProtection();
      if(!ITOpenBuy(0.02)) return;
      ITAssert(true,"open trade for trailing");
      gITStep=10; return;
   }
   if(gITStep==10)
   {
      ActivateScope(0); RefreshAccounting(true);
      if(!gLedger[0].ready){ gHistoryDirty=true; return; }
      double pl=CurrentSymbolBasketProfit();
      gTrailTriggerUSD=0.01; gTrailDistanceUSD=0.50;
      gProfitTrailArmed=true; gProfitTrailPeakUSD=pl+1.0;
      gLastCloseAttempt[0]=0; CheckEquityExit();
      gITStep=11; return;
   }
   if(gITStep==11)
   {
      if(CurrentSymbolPositionCount()>0)
      {
         ActivateScope(0); CheckEquityExit(); return;
      }
      ITAssert(true,"Profit trailing closes on pullback");
      ITResetProtection();
      bool a=ITOpenBuy(0.02);
      if(!a) return;
      bool b=ITOpenSell(0.02);
      if(!b) { ITCleanup(); return; }
      ITAssert(true,"open BUY+SELL for split scope");
      gITStep=12; return;
   }
   if(gITStep==12)
   {
      gSplit=true; ActivateScope(1); RefreshAccounting(true);
      gLastCloseAttempt[1]=0; CloseAllSymbolPositions(_Symbol);
      gITStep=13; return;
   }
   if(gITStep==13)
   {
      ActivateScope(1);
      ITAssert(CurrentSymbolPositionCount()==0,"BUY scope close");
      ActivateScope(2);
      ITAssert(CurrentSymbolPositionCount()==1,"SELL remains after BUY scope close");
      gLastCloseAttempt[2]=0; CloseAllSymbolPositions(_Symbol);
      gSplit=false; ActivateScope(0);
      gITStep=14; return;
   }
   if(gITStep==14)
   {
      ITAssert(CurrentSymbolPositionCount()==0,"SELL scope close");
      bool a=ITOpenBuy(0.01), b=ITOpenPending();
      ITAssert(a&&b,"open trades for account-wide close");
      gITStep=15; return;
   }
   if(gITStep==15)
   {
      gAccountClosing=true;
      ProcessAccountEquity();
      gITStep=16; return;
   }
   if(gITStep==16)
   {
      if(PositionsTotal()>0 || OrdersTotal()>0)
      {
         ProcessAccountEquity();
         return;
      }
      ITAssert(PositionsTotal()==0 && OrdersTotal()==0,
               "account-wide close positions + pending");
      ITFinish(); return;
   }
}

int OnInit()
{
   gTesterMode = (MQLInfoInteger(MQL_TESTER) != 0);
   gVisualMode = (!gTesterMode || MQLInfoInteger(MQL_VISUAL_MODE) != 0);
   if(gVisualMode)
   {
      gObjectCreateEventWasEnabled = (ChartGetInteger(0, CHART_EVENT_OBJECT_CREATE) != 0);
      if(!gObjectCreateEventWasEnabled)
         ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
      // Existing trade-history objects are scanned gradually by the 1-second timer.
      // This keeps EA startup fast even on charts with very long histories.
      gHistoryInitialScanCursor = -2;
   }
   if(InpMagicNumber < -1 || InpSlippagePoints < 0) return INIT_PARAMETERS_INCORRECT;
   bool hedging = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(!hedging && (InpMagicNumber >= 0 || InpSeparateSides))
   {
      Print("Magic filtering and separate BUY/SELL baskets require a hedging account. Netting: use Magic=-1 and combined mode.");
      return INIT_PARAMETERS_INCORRECT;
   }
   gStateKey = BuildStateKey();
   if(!InitAccountEquity()) return INIT_PARAMETERS_INCORRECT;
   gManageWholeBasket = (!gTesterMode && GlobalVariableCheck(gStateKey + "_MANAGE_WHOLE") &&
                         GlobalVariableGet(gStateKey + "_MANAGE_WHOLE") != 0.0);
   gSplit = InpSeparateSides;
   for(int scope = 0; scope < 3; scope++)
   {
      gScope = scope;
      gPositiveUSD = scope == 0 ? InpDefaultPosUSD : InpSideDefaultTP;
      gNegativeUSD = scope == 0 ? InpDefaultNegUSD : InpSideDefaultSL;
      gNegativeProfitLock = scope == 0 && InpDefaultNegProfitLock;
      gTrailTriggerUSD = scope == 0 ? InpDefaultTrailTriggerUSD : 0.0;
      gTrailDistanceUSD = scope == 0 ? InpDefaultTrailDistanceUSD : 0.0;
      ResetProfitTrailState(); ResetBasketSLState(); ResetBreakevenState();
      if(gTesterMode && InpUseTesterInputs && scope == 0) ApplyTesterInputs();
      else LoadPersistentSettings();
      CaptureScope();
      LoadLedger(scope);
   }
   if(!gTesterMode && GlobalVariableCheck(gStateKey + "_MODE"))
      gSplit = hedging && GlobalVariableGet(gStateKey + "_MODE") != 0.0;
   ActivateScope(gSplit ? 1 : 0);
   RefreshAccounting(true);
   trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   trade.SetAsyncMode(false);
   if(gVisualMode)
   {
      if(!CreatePanel()) return INIT_FAILED;
      gPanelCreated = true;
      SyncPanelFields();
   }
EventSetTimer(1);
   UpdatePanelStatus();
return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
if(gStateKey != "")
   {
      ReadPanelValues(false);
      CaptureScope();
      SaveAllScopes();
   }
   if(gPanelCreated) DeletePanel();
   RestoreTradeHistoryObjectLayer();
   if(!gObjectCreateEventWasEnabled)
      ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, false);
}
void OnTick()
{
   ProcessBaskets();
   IntegrationSelfTest();
}
void OnTimer()
{
   ProcessBaskets();
   ContinueInitialTradeHistoryScan();
   if(gHistoryRescanTicks > 0)
   {
      PutRecentTradeHistoryBehindPanel();
      gHistoryRescanTicks--;
   }
UpdatePanelStatus();
}
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   gHistoryDirty = true;
   // Fallback for terminal-created trade-history objects: inspect only the newest
   // chart objects on the next two timer cycles, never on every tick.
   gHistoryRescanTicks = 2;
}
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CREATE && IsTradeHistoryObject(sparam))
   {
      if(PutTradeHistoryObjectBehindPanel(sparam))
         ChartRedraw(0);
      return;
   }

   if(!gPanelCreated)
      return;

   if(id == CHARTEVENT_OBJECT_ENDEDIT)
   {
      if(sparam==ObjName("EDIT_EQTP") || sparam==ObjName("EDIT_EQSL"))
      {
         CommitAccountEquity(sparam);
         ProcessAccountEquity();
         UpdatePanelStatus();
         return;
      }
      if(sparam == ObjName("EDIT_POS") ||
         sparam == ObjName("EDIT_NEG") ||
         sparam == ObjName("EDIT_TRAIL_TRIGGER") ||
         sparam == ObjName("EDIT_TRAIL"))
      {
         ReadPanelValues(true);
         UpdatePanelStatus();
      }
      return;
   }

   if(gAccountClosing) return;

   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam == ObjName("BTN_MANAGE_SYMBOL") || sparam == ObjName("BTN_MANAGE_WHOLE"))
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      gManageWholeBasket = (sparam == ObjName("BTN_MANAGE_WHOLE"));
      SaveManageMode();
      gHalfCloseStatus = "Manual close scope: " + ManageModeName();
      UpdatePanelStatus();
      return;
   }

   if(sparam == ObjName("BTN_MODE"))
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      {
         gHalfCloseStatus = "Split mode requires a hedging account";
         UpdatePanelStatus(); return;
      }
      ReadPanelValues(true); CaptureScope();
      gSplit = !gSplit;
      ActivateScope(gSplit ? 1 : 0);
      SyncPanelFields(); SaveAllScopes(); UpdatePanelStatus(); return;
   }
   if(sparam == ObjName("BTN_BUY") || sparam == ObjName("BTN_SELL"))
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      if(!gSplit) { gHalfCloseStatus = "Select MODE: SPLIT for separate BUY/SELL"; UpdatePanelStatus(); return; }
      ReadPanelValues(true); CaptureScope();
      ActivateScope(sparam == ObjName("BTN_BUY") ? 1 : 2);
      SyncPanelFields(); UpdatePanelStatus(); return;
   }
   if(sparam == ObjName("BTN_HALF_BE"))
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ReadPanelValues(true);
      RefreshAccounting(true);
      if(!gLedger[gScope].ready) { gHalfCloseStatus = "50% + BE: history not ready"; UpdatePanelStatus(); return; }
      CloseHalfSymbolPositions();
      if(gLastHalfFilled > 0.0 && CurrentSymbolPositionCount() > 0 && gLedger[gScope].ready)
      {
         gBreakevenMode = CurrentSymbolBasketProfit() < 0.0 ? BREAKEVEN_RECOVERY : BREAKEVEN_PROTECT;
         gHalfCloseStatus += " | BE ON";
      }
      else if(gLastHalfFilled > 0.0 && CurrentSymbolPositionCount() > 0)
      {
         gPendingHalfBE[gScope] = true;
         gHalfCloseStatus += " | BE waits for history";
      }
      CaptureScope(); UpdatePanelStatus(); return;
   }
   if(sparam == ObjName("BTN_BREAKEVEN"))
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      RefreshAccounting(true);
      if(gLedger[gScope].ready) ToggleBreakeven();
      UpdatePanelStatus();
      return;
   }

   if(sparam == ObjName("BTN_HALF"))
   {
      ObjectSetInteger(0, ObjName("BTN_HALF"), OBJPROP_STATE, false);
      ReadPanelValues(true);
      CloseHalfSymbolPositions();
      UpdatePanelStatus();
      return;
   }

   if(sparam == ObjName("BTN_CLOSE"))
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      CloseAllNow();
      UpdatePanelStatus();
      return;
   }
}
//+------------------------------------------------------------------+
