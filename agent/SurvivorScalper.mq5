// Survivor Scalper: trades the break of the Asian range on several symbols from one chart.
// It compounds by risking a fixed share of equity, and "dies" (closes its trades, never trades again)
// when equity falls to DeathEquity, or when the balance makes no new high for StallDays. Starts on demo accounts only unless AllowLive is turned on by its owner.
#property version "1.10"
#property strict
#include <Trade/Trade.mqh>

input bool   AllowLive         = false;  // Allow a REAL account (the owner's decision)
input string Symbols           = "EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,USDCAD,NZDUSD,XAUUSD";
input double RiskPct           = 1.0;    // Equity risked per trade, %
input double MinLotMaxRiskPct  = 3.0;    // Use the minimum lot only if it risks no more than this, %
input double MaxOpenRiskPct    = 4.0;    // Total risk open at once, %
input double DailyLossPct      = 5.0;    // Stop for the day after losing this, %
input double DeathEquity       = 50.0;    // The agent dies at this equity (account currency)
input int    StallDays         = 60;     // Dies after this many days without a new balance high
input double MinFlow           = 0.2;    // Order-flow agreement needed to enter (0 = off)
input double TargetR           = 2.0;    // Target as a multiple of the stop
input double MaxSpreadOfStop   = 6.0;    // Skip if spread is more than this % of the stop
input int    MaxTradesPerDay   = 2;      // Per symbol
input int    NewsMinutes       = 20;     // No entries this close to high-impact news (live only)
input long   Magic             = 20261124;

CTrade   trade;
string   names[];
datetime lastBar[];
bool     halted = false;

string Key(string k) { return StringFormat("SURV_%I64d_%I64d_%s", AccountInfoInteger(ACCOUNT_LOGIN), Magic, k); }
bool   Tester()      { return (bool)MQLInfoInteger(MQL_TESTER); }

// EU summer time: last Sunday of March to last Sunday of October, 01:00 UTC.
datetime LastSunday(int year, int month)
{
   datetime t = StringToTime(StringFormat("%d.%02d.31 01:00", year, month));
   MqlDateTime d;
   TimeToStruct(t, d);
   return t - d.day_of_week * 86400;
}

// Server minus UTC, in seconds. The tester has no real UTC clock, so it assumes EET/EEST (XM's server time).
int ServerOffset()
{
   if(!Tester()) return (int)MathRound((double)(TimeTradeServer() - TimeGMT()) / 1800.0) * 1800;
   datetime utc = TimeCurrent() - 7200;
   MqlDateTime d;
   TimeToStruct(utc, d);
   return (utc >= LastSunday(d.year, 3) && utc < LastSunday(d.year, 10)) ? 10800 : 7200;
}

int OnInit()
{
   if(!Tester() && AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO && !AllowLive)
   {
      Alert("Survivor Scalper: this is not a demo account and AllowLive is off.");
      return INIT_FAILED;
   }
   if(RiskPct <= 0 || RiskPct > MinLotMaxRiskPct || MaxOpenRiskPct < RiskPct || DailyLossPct <= 0 || DeathEquity < 0 || StallDays <= 0 || TargetR <= 0)
      return INIT_PARAMETERS_INCORRECT;
   if(!GlobalVariableCheck(Key("dead")) && !GlobalVariableCheck(Key("peak")) && AccountInfoDouble(ACCOUNT_EQUITY) <= DeathEquity)
   {
      Alert("Survivor Scalper: equity must start above DeathEquity.");
      return INIT_FAILED;
   }
   string suffix = StringSubstr(_Symbol, 6);  // EURUSDmicro -> "micro", EURUSD# -> "#"
   string list[];
   int n = StringSplit(Symbols, ',', list);
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(list[i]);
      StringTrimRight(list[i]);
      string s = list[i] + suffix;
      if(!SymbolSelect(s, true)) { Print("Not offered here, skipped: ", s); continue; }
      int k = ArraySize(names);
      ArrayResize(names, k + 1);
      ArrayResize(lastBar, k + 1);
      names[k] = s;
      lastBar[k] = iTime(s, PERIOD_M15, 0);  // never act on a bar that closed before the start
   }
   if(ArraySize(names) == 0) return INIT_FAILED;
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(10);
   EventSetTimer(2);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }
void OnTimer() { Run(); }
void OnTick()  { Run(); }

int CloseOwn(string symbol = "")
{
   int left = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(symbol != "" && PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(!trade.PositionClose(ticket)) left++;
   }
   return left;
}

// Loss in account currency if every open trade of this agent hits its stop; also reports whether one is on `symbol`.
double OpenRisk(string symbol, bool &busy)
{
   double risk = 0;
   busy = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0 || PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      string s = PositionGetString(POSITION_SYMBOL);
      if(s == symbol) busy = true;
      double p = 0, sl = PositionGetDouble(POSITION_SL);
      ENUM_ORDER_TYPE type = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(sl > 0 && OrderCalcProfit(type, s, PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), sl, p) && p < 0)
         risk -= p;
   }
   return risk;
}

int TradesToday(string symbol)
{
   int n = 0;
   if(!HistorySelect(TimeCurrent() - TimeCurrent() % 86400, TimeCurrent() + 86400)) return MaxTradesPerDay;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == Magic && HistoryDealGetString(t, DEAL_SYMBOL) == symbol &&
         HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN) n++;
   }
   return n;
}

bool NewsNear(string symbol)
{
   if(Tester() || NewsMinutes <= 0) return false;  // the tester has no calendar
   string ccy[2];
   ccy[0] = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   ccy[1] = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   datetime now = TimeTradeServer();
   for(int c = 0; c < 2; c++)
   {
      MqlCalendarValue v[];
      if(!CalendarValueHistory(v, now - NewsMinutes * 60, now + NewsMinutes * 60, NULL, ccy[c])) continue;
      for(int i = 0; i < ArraySize(v); i++)
      {
         MqlCalendarEvent e;
         if(CalendarEventById(v[i].event_id, e) && e.importance == CALENDAR_IMPORTANCE_HIGH) return true;
      }
   }
   return false;
}

double Lots(string s, ENUM_ORDER_TYPE type, double price, double sl, double equity)
{
   double lossPerLot = 0, step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP), lo = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   if(step <= 0 || !OrderCalcProfit(type, s, 1.0, price, sl, lossPerLot) || lossPerLot >= 0) return 0;
   lossPerLot = -lossPerLot;
   double lots = MathFloor(equity * RiskPct / 100 / lossPerLot / step + 1e-9) * step;
   if(lots < lo)
   {
      if(lo * lossPerLot > equity * MinLotMaxRiskPct / 100) return 0;  // too big for this account: stay out
      lots = lo;
   }
   lots = MathMin(lots, SymbolInfoDouble(s, SYMBOL_VOLUME_MAX));
   double margin = 0;
   if(!OrderCalcMargin(type, s, lots, price, margin) || margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.5) return 0;
   return NormalizeDouble(lots, 8);
}

// +1 buy, -1 sell, 0 nothing. `range` is the 00:00-07:00 UTC high minus low.
int Signal(string s, int offset, double &range)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(s, PERIOD_M15, 1, 60, r);
   if(got < 50) return 0;
   datetime utc = r[0].time - offset;
   int hour = (int)(utc % 86400 / 3600);
   if(hour < 7 || hour >= 11) return 0;
   datetime day = utc - utc % 86400;
   double hi = 0, lo = DBL_MAX;
   int bars = 0;
   for(int i = 0; i < got; i++)
   {
      datetime t = r[i].time - offset;
      if(t < day || t >= day + 7 * 3600) continue;
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
      bars++;
   }
   if(bars < 20) return 0;
   range = hi - lo;
   // Buying vs selling pressure: tick volume weighted by where each of the last 6 bars closed, -1..+1.
   // shortcut: forex has no central tape, so tick volume stands in; use a futures feed if one is connected.
   double flow = 0, vol = 0;
   for(int i = 0; i < 6; i++)
   {
      double v = (double)r[i].tick_volume, h = r[i].high - r[i].low;
      if(h > 0) flow += v * (2 * r[i].close - r[i].high - r[i].low) / h;
      vol += v;
   }
   flow = vol > 0 ? flow / vol : 0;
   if(r[0].close > hi && r[1].close <= hi && (MinFlow <= 0 || flow > MinFlow)) return 1;
   if(r[0].close < lo && r[1].close >= lo && (MinFlow <= 0 || flow < -MinFlow)) return -1;
   return 0;
}

void TryEntry(string s, int offset, double equity)
{
   double range = 0;
   int dir = Signal(s, offset, range);
   if(dir == 0 || range <= 0) return;
   bool busy;
   double open = OpenRisk(s, busy);
   if(busy || TradesToday(s) >= MaxTradesPerDay || NewsNear(s)) return;
   double ask = SymbolInfoDouble(s, SYMBOL_ASK), bid = SymbolInfoDouble(s, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || (ask - bid) > range * MaxSpreadOfStop / 100) return;
   if(range < SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(s, SYMBOL_POINT)) return;
   ENUM_ORDER_TYPE type = dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = dir > 0 ? ask : bid, tick = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   if(tick <= 0) return;
   double sl = NormalizeDouble(MathRound((price - dir * range) / tick) * tick, digits);
   double tp = NormalizeDouble(MathRound((price + dir * range * TargetR) / tick) * tick, digits);
   double lots = Lots(s, type, price, sl, equity), loss = 0;
   if(lots <= 0 || !OrderCalcProfit(type, s, lots, price, sl, loss)) { Print(s, ": signal skipped, account too small"); return; }
   if(open - loss > equity * MaxOpenRiskPct / 100) return;
   trade.SetTypeFillingBySymbol(s);
   if(!trade.PositionOpen(s, type, lots, price, sl, tp, "survivor"))
      Print(s, ": order refused, ", trade.ResultRetcodeDescription());
}

void Run()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(AccountInfoInteger(ACCOUNT_LOGIN) == 0 || AccountInfoDouble(ACCOUNT_BALANCE) <= 0) return;  // not connected yet

   // shortcut: a withdrawal lowers the balance and counts as stalling; reset by removing the SURV_ variables (F3).
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!GlobalVariableCheck(Key("peak")) || balance > GlobalVariableGet(Key("peak")))
   {
      GlobalVariableSet(Key("peak"), balance);
      GlobalVariableSet(Key("peaktime"), (double)TimeCurrent());
   }
   bool stalled = (double)TimeCurrent() - GlobalVariableGet(Key("peaktime")) > StallDays * 86400.0;
   if(GlobalVariableCheck(Key("dead")) || stalled || equity <= DeathEquity)
   {
      if(!GlobalVariableCheck(Key("dead")))
      {
         GlobalVariableSet(Key("dead"), (double)TimeCurrent());
         GlobalVariablesFlush();
         Alert("Survivor Scalper died at equity ", DoubleToString(equity, 2), stalled ? " (stopped compounding)" : " (lost too much)");
      }
      if(CloseOwn() == 0) ExpertRemove();
      return;
   }

   int offset = ServerOffset();
   datetime utc = (Tester() ? TimeCurrent() : TimeTradeServer()) - offset;
   double today = (double)(utc - utc % 86400);
   if(!GlobalVariableCheck(Key("day")) || GlobalVariableGet(Key("day")) != today)
   {
      GlobalVariableSet(Key("day"), today);
      GlobalVariableSet(Key("start"), equity);
   }
   double start = GlobalVariableGet(Key("start"));
   halted = equity <= start * (1 - DailyLossPct / 100);
   if(halted) CloseOwn();

   int hour = (int)(utc % 86400 / 3600);
   if(hour >= 16 || hour < 7) CloseOwn();  // flat outside the session, so nothing is held overnight

   for(int i = 0; i < ArraySize(names); i++)
   {
      datetime bar = iTime(names[i], PERIOD_M15, 0);
      if(bar == 0 || bar == lastBar[i]) continue;
      lastBar[i] = bar;  // one attempt per bar, even if the order is refused
      if(!halted) TryEntry(names[i], offset, equity);
   }
   Comment(StringFormat("Survivor Scalper\nEquity %.2f   dies at %.2f\nToday %+.2f%%%s\nUTC hour %d",
           equity, DeathEquity, start > 0 ? 100 * (equity / start - 1) : 0, halted ? "   HALTED until tomorrow" : "", hour));
}
