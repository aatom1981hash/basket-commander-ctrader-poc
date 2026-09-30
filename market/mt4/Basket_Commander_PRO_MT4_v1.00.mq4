#property strict
#property version   "1.00"
#property description "Basket Commander PRO MT4: advanced basket, position and account-equity trade management utility."

enum ENUM_BC_SCOPE
{
   BC_SCOPE_BOTH = 0,
   BC_SCOPE_BUY  = 1,
   BC_SCOPE_SELL = 2
};

enum ENUM_BC_BE_MODE
{
   BC_BE_OFF      = 0,
   BC_BE_RECOVERY = 1,
   BC_BE_PROTECT  = 2
};

input int      InpMagicNumber             = -1;     // -1 = all magic numbers, 0 = manual trades
input bool     InpSeparateSides           = false;  // Split BUY/SELL baskets
input int      InpPanelCorner             = 0;      // 0=left upper, 1=right upper, 2=left lower, 3=right lower
input int      InpPanelX                  = 1;
input int      InpPanelY                  = 80;
input double   InpDefaultBasketTP         = 0.0;    // Account currency; 0 = off
input double   InpDefaultBasketSL         = 0.0;    // Loss magnitude; 0 = off
input double   InpDefaultTrailTrigger     = 0.0;    // Account currency; 0 = off
input double   InpDefaultTrailDistance    = 0.0;    // Account currency; 0 = off
input double   InpAccountEquityTP         = 0.0;    // Absolute account equity; 0 = off
input double   InpAccountEquitySL         = 0.0;    // Absolute account equity; 0 = off
input int      InpSlippagePoints          = 20;

string PREFIX = "BCPRO4_100_";

struct ScopeState
{
   double tp;
   double sl;
   double trigger;
   double distance;
   double peak;
   int    be;
   bool   trailArmed;
   datetime cycleStart;
};

ScopeState g_state[3];
int  g_scope = BC_SCOPE_BOTH;
bool g_split = false;
bool g_manageWhole = false;
bool g_panel = false;
bool g_accountClosing = false;
string g_stateKey = "";

string Obj(string suffix) { return PREFIX + suffix; }

bool IsMarketType(int type)
{
   return type == OP_BUY || type == OP_SELL;
}
bool IsPendingType(int type)
{
   return type == OP_BUYLIMIT || type == OP_BUYSTOP || type == OP_SELLLIMIT || type == OP_SELLSTOP;
}
bool DirectionMatches(int type,int scope)
{
   if(scope == BC_SCOPE_BOTH) return type == OP_BUY || type == OP_SELL;
   if(scope == BC_SCOPE_BUY) return type == OP_BUY;
   return type == OP_SELL;
}
bool PendingDirectionMatches(int type,int scope)
{
   if(scope == BC_SCOPE_BOTH) return IsPendingType(type);
   if(scope == BC_SCOPE_BUY) return type == OP_BUYLIMIT || type == OP_BUYSTOP;
   return type == OP_SELLLIMIT || type == OP_SELLSTOP;
}
bool MagicMatches()
{
   return InpMagicNumber < 0 || OrderMagicNumber() == InpMagicNumber;
}
bool SymbolMatches(bool whole)
{
   return whole || OrderSymbol() == Symbol();
}
bool SelectTradeByPos(int pos)
{
   return OrderSelect(pos,SELECT_BY_POS,MODE_TRADES);
}
bool SelectHistoryByPos(int pos)
{
   return OrderSelect(pos,SELECT_BY_POS,MODE_HISTORY);
}

int ScopePositionCount(int scope,bool whole=false)
{
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!SelectTradeByPos(i)) continue;
      if(!IsMarketType(OrderType())) continue;
      if(!SymbolMatches(whole) || !MagicMatches() || !DirectionMatches(OrderType(),scope)) continue;
      n++;
   }
   return n;
}
double ScopeLots(int scope,bool whole=false)
{
   double lots=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!SelectTradeByPos(i)) continue;
      if(!IsMarketType(OrderType())) continue;
      if(!SymbolMatches(whole) || !MagicMatches() || !DirectionMatches(OrderType(),scope)) continue;
      lots += OrderLots();
   }
   return lots;
}
double ScopeFloating(int scope)
{
   double p=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!SelectTradeByPos(i)) continue;
      if(!IsMarketType(OrderType()) || OrderSymbol()!=Symbol() || !MagicMatches() || !DirectionMatches(OrderType(),scope)) continue;
      p += OrderProfit()+OrderSwap()+OrderCommission();
   }
   return p;
}
double ScopeRealized(int scope)
{
   datetime start=g_state[scope].cycleStart;
   if(start<=0) return 0;
   double p=0;
   for(int i=OrdersHistoryTotal()-1;i>=0;i--)
   {
      if(!SelectHistoryByPos(i)) continue;
      if(OrderCloseTime()<start) break;
      if(!IsMarketType(OrderType()) || OrderSymbol()!=Symbol() || !MagicMatches() || !DirectionMatches(OrderType(),scope)) continue;
      p += OrderProfit()+OrderSwap()+OrderCommission();
   }
   return p;
}
double BasketPL(int scope)
{
   return ScopeFloating(scope)+ScopeRealized(scope);
}

string Key(int scope,string name)
{
   return g_stateKey+"_"+IntegerToString(scope)+"_"+name;
}
void SaveScope(int scope)
{
   GlobalVariableSet(Key(scope,"TP"),g_state[scope].tp);
   GlobalVariableSet(Key(scope,"SL"),g_state[scope].sl);
   GlobalVariableSet(Key(scope,"TRIG"),g_state[scope].trigger);
   GlobalVariableSet(Key(scope,"DIST"),g_state[scope].distance);
   GlobalVariableSet(Key(scope,"PEAK"),g_state[scope].peak);
   GlobalVariableSet(Key(scope,"BE"),g_state[scope].be);
   GlobalVariableSet(Key(scope,"TRAIL"),g_state[scope].trailArmed ? 1.0 : 0.0);
   GlobalVariableSet(Key(scope,"START"),g_state[scope].cycleStart);
}
void LoadScope(int scope)
{
   g_state[scope].tp       = GlobalVariableCheck(Key(scope,"TP")) ? GlobalVariableGet(Key(scope,"TP")) : (scope==0?InpDefaultBasketTP:0);
   g_state[scope].sl       = GlobalVariableCheck(Key(scope,"SL")) ? GlobalVariableGet(Key(scope,"SL")) : (scope==0?InpDefaultBasketSL:0);
   g_state[scope].trigger  = GlobalVariableCheck(Key(scope,"TRIG")) ? GlobalVariableGet(Key(scope,"TRIG")) : (scope==0?InpDefaultTrailTrigger:0);
   g_state[scope].distance = GlobalVariableCheck(Key(scope,"DIST")) ? GlobalVariableGet(Key(scope,"DIST")) : (scope==0?InpDefaultTrailDistance:0);
   g_state[scope].peak     = GlobalVariableCheck(Key(scope,"PEAK")) ? GlobalVariableGet(Key(scope,"PEAK")) : 0;
   g_state[scope].be       = GlobalVariableCheck(Key(scope,"BE")) ? (int)GlobalVariableGet(Key(scope,"BE")) : BC_BE_OFF;
   g_state[scope].trailArmed = GlobalVariableCheck(Key(scope,"TRAIL")) && GlobalVariableGet(Key(scope,"TRAIL"))!=0;
   g_state[scope].cycleStart = GlobalVariableCheck(Key(scope,"START")) ? (datetime)GlobalVariableGet(Key(scope,"START")) : 0;
}
void SaveGlobal()
{
   GlobalVariableSet(g_stateKey+"_MODE",g_split?1.0:0.0);
   GlobalVariableSet(g_stateKey+"_WHOLE",g_manageWhole?1.0:0.0);
   GlobalVariableSet(g_stateKey+"_EQTP",InpAccountEquityTP);
   GlobalVariableSet(g_stateKey+"_EQSL",InpAccountEquitySL);
   for(int s=0;s<3;s++) SaveScope(s);
   GlobalVariablesFlush();
}

double NormalizeLots(string sym,double lots)
{
   double step=MarketInfo(sym,MODE_LOTSTEP);
   double minlot=MarketInfo(sym,MODE_MINLOT);
   if(step<=0) step=0.01;
   int digits=2;
   if(step>=1.0) digits=0;
   else if(step>=0.1) digits=1;
   else if(step>=0.01) digits=2;
   else digits=3;
   double v=MathFloor(lots/step+1e-9)*step;
   v=NormalizeDouble(v,digits);
   if(v<minlot) return 0;
   return v;
}
bool CloseTicket(int ticket,double lots)
{
   if(!OrderSelect(ticket,SELECT_BY_TICKET)) return false;
   if(!IsMarketType(OrderType())) return false;
   string sym=OrderSymbol();
   double price = OrderType()==OP_BUY ? MarketInfo(sym,MODE_BID) : MarketInfo(sym,MODE_ASK);
   ResetLastError();
   bool ok=OrderClose(ticket,lots,price,InpSlippagePoints,clrNONE);
   if(!ok) Print("Basket Commander PRO MT4 close failed ticket=",ticket," err=",GetLastError());
   return ok;
}
void CloseHalf()
{
   int scope=g_scope;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!SelectTradeByPos(i)) continue;
      if(!IsMarketType(OrderType()) || !MagicMatches() || !SymbolMatches(g_manageWhole) || !DirectionMatches(OrderType(),scope)) continue;
      int ticket=OrderTicket();
      string sym=OrderSymbol();
      double before=OrderLots();
      double closeLots=NormalizeLots(sym,before/2.0);
      double minlot=MarketInfo(sym,MODE_MINLOT);
      double remain=NormalizeLots(sym,before-closeLots);
      if(closeLots<=0 || remain<minlot-1e-9) continue;
      CloseTicket(ticket,closeLots);
   }
}
void DeletePending(int scope,bool whole)
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!SelectTradeByPos(i)) continue;
      if(!IsPendingType(OrderType()) || !MagicMatches() || !SymbolMatches(whole) || !PendingDirectionMatches(OrderType(),scope)) continue;
      int ticket=OrderTicket();
      ResetLastError();
      if(!OrderDelete(ticket,clrNONE))
         Print("Basket Commander PRO MT4 pending delete failed ticket=",ticket," err=",GetLastError());
   }
}
void CloseBasket(int scope,bool whole)
{
   DeletePending(scope,whole);
   for(int pass=0;pass<3;pass++)
   {
      bool any=false;
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         if(!SelectTradeByPos(i)) continue;
         if(!IsMarketType(OrderType()) || !MagicMatches() || !SymbolMatches(whole) || !DirectionMatches(OrderType(),scope)) continue;
         int ticket=OrderTicket();
         double lots=OrderLots();
         any=true;
         CloseTicket(ticket,lots);
      }
      if(!any) break;
   }
}
void CloseAllAccount()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!SelectTradeByPos(i)) continue;
      int ticket=OrderTicket(), type=OrderType();
      if(IsPendingType(type)) OrderDelete(ticket,clrNONE);
      else if(IsMarketType(type)) CloseTicket(ticket,OrderLots());
   }
}

void MaintainCycle(int scope)
{
   int n=ScopePositionCount(scope,false);
   if(n>0 && g_state[scope].cycleStart<=0)
   {
      g_state[scope].cycleStart=TimeCurrent();
      g_state[scope].peak=0;
      g_state[scope].trailArmed=false;
      g_state[scope].be=BC_BE_OFF;
      SaveScope(scope);
   }
   if(n==0 && g_state[scope].cycleStart>0)
   {
      g_state[scope].cycleStart=0;
      g_state[scope].peak=0;
      g_state[scope].trailArmed=false;
      g_state[scope].be=BC_BE_OFF;
      SaveScope(scope);
   }
}
void CheckScope(int scope)
{
   MaintainCycle(scope);
   if(ScopePositionCount(scope,false)<=0) return;
   double pl=BasketPL(scope);
   ScopeState st=g_state[scope];

   if(st.tp>0 && pl>=st.tp)
   {
      CloseBasket(scope,false);
      return;
   }
   if(st.sl>0 && pl<=-st.sl)
   {
      CloseBasket(scope,false);
      return;
   }

   if(st.be==BC_BE_RECOVERY && pl>=0)
   {
      CloseBasket(scope,false);
      return;
   }
   if(st.be==BC_BE_PROTECT && pl<=0)
   {
      CloseBasket(scope,false);
      return;
   }

   if(st.trigger>0 && st.distance>0)
   {
      if(!g_state[scope].trailArmed && pl>=st.trigger)
      {
         g_state[scope].trailArmed=true;
         g_state[scope].peak=pl;
         SaveScope(scope);
      }
      if(g_state[scope].trailArmed)
      {
         if(pl>g_state[scope].peak)
         {
            g_state[scope].peak=pl;
            SaveScope(scope);
         }
         if(pl<=g_state[scope].peak-g_state[scope].distance)
         {
            CloseBasket(scope,false);
            return;
         }
      }
   }
}
void CheckAccountEquity()
{
   double eq=AccountEquity();
   if(!g_accountClosing)
   {
      if(InpAccountEquitySL>0 && eq<=InpAccountEquitySL) g_accountClosing=true;
      if(InpAccountEquityTP>0 && eq>=InpAccountEquityTP) g_accountClosing=true;
   }
   if(g_accountClosing)
   {
      CloseAllAccount();
      if(OrdersTotal()==0) g_accountClosing=false;
   }
}

void SetText(string name,string text,int x,int y,int w=410,int size=9,color c=clrBlack)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,size);
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}
void SetButton(string name,string text,int x,int y,int w,int h,color bg)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}
void SetEdit(string name,string text,int x,int y,int w,int h)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
}
void CreatePanel()
{
   int x=InpPanelX,y=InpPanelY;
   string bg=Obj("BG");
   ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bg,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,650);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,455);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,clrGainsboro);
   ObjectSetInteger(0,bg,OBJPROP_BORDER_COLOR,clrGray);
   ObjectSetInteger(0,bg,OBJPROP_BACK,false);
   ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);

   SetText(Obj("TITLE"),"Basket Commander PRO MT4 v1.00",x+12,y+10,410,11,clrBlack);
   SetText(Obj("TP_L"),"Basket TP",x+12,y+45); SetEdit(Obj("TP"),DoubleToString(g_state[g_scope].tp,2),x+135,y+40,110,22);
   SetText(Obj("SL_L"),"Basket SL",x+12,y+75); SetEdit(Obj("SL"),DoubleToString(g_state[g_scope].sl,2),x+135,y+70,110,22);
   SetText(Obj("TR_L"),"Trail trigger",x+12,y+105); SetEdit(Obj("TR"),DoubleToString(g_state[g_scope].trigger,2),x+135,y+100,110,22);
   SetText(Obj("TD_L"),"Trail distance",x+12,y+135); SetEdit(Obj("TD"),DoubleToString(g_state[g_scope].distance,2),x+135,y+130,110,22);

   SetButton(Obj("HALF"),"CLOSE 50%",x+12,y+170,115,34,clrDarkOrange);
   SetButton(Obj("HALFBE"),"50% + BE",x+135,y+170,110,34,clrSteelBlue);
   SetButton(Obj("BE"),"BREAKEVEN",x+12,y+212,115,34,clrDimGray);
   SetButton(Obj("CLOSE"),"CLOSE BASKET",x+135,y+212,110,34,clrRed);
   SetButton(Obj("MODE"),g_split?"MODE: SPLIT":"MODE: COMBINED",x+12,y+254,150,34,clrDimGray);
   SetButton(Obj("BUY"),"BUY",x+170,y+254,75,34,clrDimGray);
   SetButton(Obj("SELL"),"SELL",x+253,y+254,75,34,clrDimGray);

   SetText(Obj("EQ_TITLE"),"ACCOUNT EQUITY - ALL TRADES",x+350,y+12,280,10,clrBlack);
   SetText(Obj("EQ"),"Equity: "+DoubleToString(AccountEquity(),2),x+350,y+45,280,10,clrBlack);
   SetText(Obj("EQTP"),"TP: "+DoubleToString(InpAccountEquityTP,2),x+350,y+72);
   SetText(Obj("EQSL"),"SL: "+DoubleToString(InpAccountEquitySL,2),x+350,y+92);
   SetText(Obj("M_TITLE"),"MANUAL CLOSE SCOPE",x+350,y+130);
   SetButton(Obj("MS"),"MANAGE SYMBOL BASKET",x+350,y+155,280,34,clrForestGreen);
   SetButton(Obj("MW"),"MANAGE WHOLE BASKET",x+350,y+197,280,34,clrDimGray);
   SetText(Obj("STATUS"),"",x+12,y+310,610,9,clrBlack);
   SetText(Obj("STATUS2"),"",x+12,y+332,610,9,clrBlack);
   SetText(Obj("STATUS3"),"",x+12,y+354,610,9,clrBlack);
   g_panel=true;
}
void DeletePanel()
{
   for(int i=ObjectsTotal()-1;i>=0;i--)
   {
      string n=ObjectName(i);
      if(StringFind(n,PREFIX)==0) ObjectDelete(0,n);
   }
   g_panel=false;
}
void ReadEdits()
{
   if(!g_panel) return;
   double v;
   v=StringToDouble(ObjectGetString(0,Obj("TP"),OBJPROP_TEXT)); if(v>=0) g_state[g_scope].tp=v;
   v=StringToDouble(ObjectGetString(0,Obj("SL"),OBJPROP_TEXT)); if(v>=0) g_state[g_scope].sl=v;
   v=StringToDouble(ObjectGetString(0,Obj("TR"),OBJPROP_TEXT)); if(v>=0) g_state[g_scope].trigger=v;
   v=StringToDouble(ObjectGetString(0,Obj("TD"),OBJPROP_TEXT)); if(v>=0) g_state[g_scope].distance=v;
   SaveScope(g_scope);
}
void SyncEdits()
{
   if(!g_panel) return;
   ObjectSetString(0,Obj("TP"),OBJPROP_TEXT,DoubleToString(g_state[g_scope].tp,2));
   ObjectSetString(0,Obj("SL"),OBJPROP_TEXT,DoubleToString(g_state[g_scope].sl,2));
   ObjectSetString(0,Obj("TR"),OBJPROP_TEXT,DoubleToString(g_state[g_scope].trigger,2));
   ObjectSetString(0,Obj("TD"),OBJPROP_TEXT,DoubleToString(g_state[g_scope].distance,2));
   ObjectSetString(0,Obj("MODE"),OBJPROP_TEXT,g_split?"MODE: SPLIT":"MODE: COMBINED");
}
void UpdatePanel()
{
   if(!g_panel) return;
   ObjectSetString(0,Obj("EQ"),OBJPROP_TEXT,"Equity: "+DoubleToString(AccountEquity(),2));
   string sc=g_scope==0?"BOTH":(g_scope==1?"BUY":"SELL");
   ObjectSetString(0,Obj("STATUS"),OBJPROP_TEXT,
                   "Scope: "+sc+" | Close: "+(g_manageWhole?"WHOLE BASKET":"SYMBOL BASKET")+
                   " | Positions: "+IntegerToString(ScopePositionCount(g_scope,g_manageWhole))+
                   " | Lots: "+DoubleToString(ScopeLots(g_scope,g_manageWhole),2));
   ObjectSetString(0,Obj("STATUS2"),OBJPROP_TEXT,
                   "Basket P/L: "+DoubleToString(BasketPL(g_scope),2)+
                   " | BE: "+IntegerToString(g_state[g_scope].be)+
                   " | Trail peak: "+DoubleToString(g_state[g_scope].peak,2));
   ObjectSetString(0,Obj("STATUS3"),OBJPROP_TEXT,
                   "Magic: "+IntegerToString(InpMagicNumber)+" | Symbol: "+Symbol());
}

int OnInit()
{
   if(InpMagicNumber < -1 || InpSlippagePoints < 0) return INIT_PARAMETERS_INCORRECT;
   if(InpAccountEquityTP<0 || InpAccountEquitySL<0) return INIT_PARAMETERS_INCORRECT;
   if(InpAccountEquityTP>0 && InpAccountEquitySL>0 && InpAccountEquitySL>=InpAccountEquityTP)
      return INIT_PARAMETERS_INCORRECT;

   g_stateKey="BCPRO4_"+IntegerToString(AccountNumber())+"_"+AccountServer()+"_"+Symbol()+"_"+IntegerToString(InpMagicNumber);
   for(int s=0;s<3;s++) LoadScope(s);
   g_split=InpSeparateSides;
   if(GlobalVariableCheck(g_stateKey+"_MODE")) g_split=GlobalVariableGet(g_stateKey+"_MODE")!=0;
   if(GlobalVariableCheck(g_stateKey+"_WHOLE")) g_manageWhole=GlobalVariableGet(g_stateKey+"_WHOLE")!=0;
   g_scope=g_split?BC_SCOPE_BUY:BC_SCOPE_BOTH;
   CreatePanel();
   SyncEdits();
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveGlobal();
   DeletePanel();
}
void OnTick()
{
   CheckAccountEquity();
   if(g_accountClosing) return;
   if(g_split) { CheckScope(BC_SCOPE_BUY); CheckScope(BC_SCOPE_SELL); }
   else CheckScope(BC_SCOPE_BOTH);
}
void OnTimer()
{
   OnTick();
   UpdatePanel();
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_ENDEDIT)
   {
      if(sparam==Obj("TP") || sparam==Obj("SL") || sparam==Obj("TR") || sparam==Obj("TD"))
      {
         ReadEdits();
         SyncEdits();
      }
      return;
   }
   if(id!=CHARTEVENT_OBJECT_CLICK) return;

   if(sparam==Obj("MS")) { g_manageWhole=false; SaveGlobal(); return; }
   if(sparam==Obj("MW")) { g_manageWhole=true; SaveGlobal(); return; }

   if(sparam==Obj("MODE"))
   {
      ReadEdits();
      g_split=!g_split;
      g_scope=g_split?BC_SCOPE_BUY:BC_SCOPE_BOTH;
      SyncEdits(); SaveGlobal(); return;
   }
   if(sparam==Obj("BUY"))
   {
      if(g_split) { ReadEdits(); g_scope=BC_SCOPE_BUY; SyncEdits(); }
      return;
   }
   if(sparam==Obj("SELL"))
   {
      if(g_split) { ReadEdits(); g_scope=BC_SCOPE_SELL; SyncEdits(); }
      return;
   }
   if(sparam==Obj("HALF"))
   {
      ReadEdits(); CloseHalf(); return;
   }
   if(sparam==Obj("HALFBE"))
   {
      ReadEdits(); CloseHalf();
      if(ScopePositionCount(g_scope,false)>0)
         g_state[g_scope].be=BasketPL(g_scope)<0?BC_BE_RECOVERY:BC_BE_PROTECT;
      SaveScope(g_scope); return;
   }
   if(sparam==Obj("BE"))
   {
      if(g_state[g_scope].be==BC_BE_OFF && ScopePositionCount(g_scope,false)>0)
         g_state[g_scope].be=BasketPL(g_scope)<0?BC_BE_RECOVERY:BC_BE_PROTECT;
      else g_state[g_scope].be=BC_BE_OFF;
      SaveScope(g_scope); return;
   }
   if(sparam==Obj("CLOSE"))
   {
      ReadEdits(); CloseBasket(g_scope,g_manageWhole); return;
   }
}
