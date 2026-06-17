//+------------------------------------------------------------------+
//|                                          InfinityTrade_EA.mq5     |
//|                  EMA200 + MACD Histogram + Color-Shift Strategy   |
//|                                                                  |
//|  Strategy (mirror of "Infinity Trade" indicator):               |
//|    BUY  : price > EMA200, MACD histogram > 0, first GREEN candle |
//|    SELL : price < EMA200, MACD histogram < 0, first RED candle   |
//|                                                                  |
//|  Money management:                                              |
//|    - Lot size from risk % and SL distance (per add).            |
//|    - Initial SL = high/low of the signal candle.                |
//|    - Pyramiding ("basket"): add a new position when a closed     |
//|      candle's BODY extends >=70% of its range further in the     |
//|      trade direction. All positions share ONE basket SL that     |
//|      trails to the current candle's high/low as trend continues. |
//|    - Sideways (yellow) candle -> close ALL positions.            |
//+------------------------------------------------------------------+
#property copyright "Generated for Dr.KOUY"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//============================ INPUTS ===============================//
input group "=== Indicator Settings ==="
input int    InpEmaLength      = 200;        // EMA Length (trend)
input int    InpMacdFast       = 12;         // MACD Fast EMA
input int    InpMacdSlow       = 26;         // MACD Slow EMA
input int    InpMacdSignal     = 9;          // MACD Signal SMA
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE; // Applied price

input group "=== Risk / Money Management ==="
input double InpRiskPercent    = 1.0;        // Risk per entry in PERCENT (1.0 = 1%, 2.5 = 2.5%)
input double InpFixedLot       = 0.0;        // Fixed lot (0 = use risk %)
input int    InpMaxPositions   = 5;          // Max stacked (basket) positions per side

input group "=== Basket / Pyramiding ==="
input bool   InpUsePyramiding  = true;       // Enable basket adds
input double InpBodyRatioAdd   = 70.0;       // Min closed-body % of range to add (>=)
input bool   InpUseSharedSL    = true;       // Shared basket SL (move all together)

input group "=== Stop Loss ==="
input int    InpSL_BufferPts   = 0;          // Extra SL buffer (points) beyond candle hi/lo
input bool   InpTrailSL        = true;       // Trail basket SL to current candle hi/lo

input group "=== Exit ==="
input bool   InpExitOnSideways = true;       // Close all on first YELLOW (sideways) candle

input group "=== General ==="
input long   InpMagicNumber    = 20260617;   // Magic number
input int    InpMaxSlippagePts = 30;         // Max slippage (points)
input string InpTradeComment   = "InfinityTrade"; // Order comment

//========================== GLOBALS ===============================//
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    sym;

int    hEMA  = INVALID_HANDLE;   // EMA200 handle
int    hMACD = INVALID_HANDLE;   // MACD handle

datetime gLastBarTime  = 0;      // last processed bar time (new-bar detection)

// Candle color codes (mirror of the Pine Script logic)
// NOTE: prefixed CC_ to avoid clashing with MQL5 built-in CLR_* color macros.
#define CC_NONE    0
#define CC_GREEN   1   // bullish trade color
#define CC_RED     2   // bearish trade color
#define CC_YELLOW  3   // sideways / momentum-against

// Current direction of an open basket
#define DIR_NONE    0
#define DIR_BUY     1
#define DIR_SELL   -1

double gPoint;
int    gDigits;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!sym.Name(_Symbol))
     {
      Print("Failed to init symbol info");
      return(INIT_FAILED);
     }
   sym.RefreshRates();

   gPoint  = _Point;
   gDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // --- Create indicator handles ---
   hEMA = iMA(_Symbol, _Period, InpEmaLength, 0, MODE_EMA, InpAppliedPrice);
   if(hEMA == INVALID_HANDLE)
     {
      Print("Failed to create EMA handle. Error=", GetLastError());
      return(INIT_FAILED);
     }

   hMACD = iMACD(_Symbol, _Period, InpMacdFast, InpMacdSlow, InpMacdSignal, InpAppliedPrice);
   if(hMACD == INVALID_HANDLE)
     {
      Print("Failed to create MACD handle. Error=", GetLastError());
      return(INIT_FAILED);
     }

   // --- Configure trade object ---
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();
   trade.LogLevel(LOG_LEVEL_ERRORS);

   // Validate inputs
   if(InpRiskPercent <= 0.0 && InpFixedLot <= 0.0)
     {
      Print("Either RiskPercent or FixedLot must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   PrintFormat("InfinityTrade EA initialized on %s %s. EMA=%d MACD=%d/%d/%d",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               InpEmaLength, InpMacdFast, InpMacdSlow, InpMacdSignal);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEMA  != INVALID_HANDLE) IndicatorRelease(hEMA);
   if(hMACD != INVALID_HANDLE) IndicatorRelease(hMACD);
  }

//+------------------------------------------------------------------+
//| Helper: read EMA value at shift                                  |
//+------------------------------------------------------------------+
bool GetEMA(int shift, double &value)
  {
   double buf[];
   if(CopyBuffer(hEMA, 0, shift, 1, buf) != 1)
      return(false);
   value = buf[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| Helper: read MACD histogram (main - signal) at shift             |
//|  In MT5 iMACD, buffer 0 = MACD main line, buffer 1 = signal.     |
//|  TradingView "hist" = macdLine - signalLine.                     |
//+------------------------------------------------------------------+
bool GetMACDHist(int shift, double &hist)
  {
   double mainBuf[], sigBuf[];
   if(CopyBuffer(hMACD, 0, shift, 1, mainBuf) != 1) return(false);
   if(CopyBuffer(hMACD, 1, shift, 1, sigBuf)  != 1) return(false);
   hist = mainBuf[0] - sigBuf[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| Determine candle color at a given shift (mirror of Pine logic)   |
//|   aboveEMA & hist>0 -> GREEN                                      |
//|   aboveEMA & hist<0 -> YELLOW                                     |
//|   belowEMA & hist<0 -> RED                                        |
//|   belowEMA & hist>0 -> YELLOW                                     |
//+------------------------------------------------------------------+
int CandleColor(int shift)
  {
   double ema, hist;
   if(!GetEMA(shift, ema))      return(CC_NONE);
   if(!GetMACDHist(shift, hist)) return(CC_NONE);

   double c = iClose(_Symbol, _Period, shift);
   bool aboveEMA = (c > ema);
   bool belowEMA = (c < ema);

   if(aboveEMA && hist > 0.0) return(CC_GREEN);
   if(aboveEMA && hist < 0.0) return(CC_YELLOW);
   if(belowEMA && hist < 0.0) return(CC_RED);
   if(belowEMA && hist > 0.0) return(CC_YELLOW);

   return(CC_NONE); // exactly on EMA or hist==0
  }

//+------------------------------------------------------------------+
//| Count EA positions on this symbol; return direction & count      |
//+------------------------------------------------------------------+
int CountPositions(int &dir)
  {
   int count = 0;
   dir = DIR_NONE;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagicNumber) continue;

      count++;
      dir = (posInfo.PositionType() == POSITION_TYPE_BUY) ? DIR_BUY : DIR_SELL;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Close ALL EA positions on this symbol                            |
//+------------------------------------------------------------------+
void CloseAllPositions(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagicNumber) continue;

      if(!trade.PositionClose(ticket))
         PrintFormat("CloseAll failed ticket=%I64u err=%d", ticket, trade.ResultRetcode());
     }
   if(reason != "")
      Print("Closed all positions: ", reason);
  }

//+------------------------------------------------------------------+
//| Normalize lot to broker constraints                              |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0) lotStep = 0.01;
   lot = MathFloor(lot / lotStep) * lotStep;

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   // round to step precision
   int lotDigits = 0;
   double s = lotStep;
   while(s < 1.0 && lotDigits < 8) { s *= 10.0; lotDigits++; }
   lot = NormalizeDouble(lot, lotDigits);
   return(lot);
  }

//+------------------------------------------------------------------+
//| Lot size from risk % and SL distance (in price)                  |
//|   risk_money = balance * risk%/100                               |
//|   lot = risk_money / (sl_distance_in_ticks * tick_value)         |
//+------------------------------------------------------------------+
double CalcLotByRisk(int dir, double entryPrice, double slPrice)
  {
   if(InpFixedLot > 0.0)
      return(NormalizeLot(InpFixedLot));

   double slDistancePrice = MathAbs(entryPrice - slPrice);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(slDistancePrice <= 0.0)
      return(NormalizeLot(minLot));

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;   // e.g. 1000 * 1.0/100 = 10

   // --- Determine the loss of exactly 1.0 lot if SL is hit. ---
   // Preferred: OrderCalcProfit gives the exact account-currency P/L for any
   // symbol (FX, metals, indices, crypto) regardless of contract size.
   double lossPerLot = 0.0;
   ENUM_ORDER_TYPE ot = (dir == DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double profitOneLot = 0.0;
   if(OrderCalcProfit(ot, _Symbol, 1.0, entryPrice, slPrice, profitOneLot))
      lossPerLot = MathAbs(profitOneLot);    // this is the loss for 1 lot at SL

   // Fallback: tick value / tick size method.
   if(lossPerLot <= 0.0)
     {
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize  <= 0.0) tickSize  = gPoint;
      if(tickValue <= 0.0) tickValue = 1.0;
      lossPerLot = (slDistancePrice / tickSize) * tickValue;
     }

   if(lossPerLot <= 0.0)
      return(NormalizeLot(minLot));

   double lot = riskMoney / lossPerLot;
   lot = NormalizeLot(lot);

   // --- Hard safety cap: never let the actual risk exceed the target. ---
   // After normalizing (rounding to lot step) recompute real risk and clamp.
   double realLoss = 0.0;
   if(OrderCalcProfit(ot, _Symbol, lot, entryPrice, slPrice, realLoss))
     {
      realLoss = MathAbs(realLoss);
      // If rounding pushed us above the risk budget, step down one lot step.
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(lotStep <= 0.0) lotStep = 0.01;
      int guard = 0;
      while(realLoss > riskMoney && lot - lotStep >= minLot && guard < 1000)
        {
         lot = NormalizeLot(lot - lotStep);
         if(!OrderCalcProfit(ot, _Symbol, lot, entryPrice, slPrice, realLoss)) break;
         realLoss = MathAbs(realLoss);
         guard++;
        }
     }

   PrintFormat("LotCalc: bal=%.2f risk%%=%.2f riskMoney=%.2f slDist=%.5f lossPerLot=%.2f -> lot=%.2f",
               balance, InpRiskPercent, riskMoney, slDistancePrice, lossPerLot, lot);
   return(lot);
  }

//+------------------------------------------------------------------+
//| Compute SL price for a NEW entry from a reference candle hi/lo   |
//|   shift: which candle to use (1 = last closed signal candle)     |
//+------------------------------------------------------------------+
double SLFromCandle(int shift, int dir)
  {
   double hi = iHigh(_Symbol, _Period, shift);
   double lo = iLow(_Symbol,  _Period, shift);
   double buf = InpSL_BufferPts * gPoint;

   double sl;
   if(dir == DIR_BUY)
      sl = lo - buf;            // below the low for a buy
   else
      sl = hi + buf;            // above the high for a sell

   return(NormalizeDouble(sl, gDigits));
  }

//+------------------------------------------------------------------+
//| Open a position in the given direction with SL from candle       |
//+------------------------------------------------------------------+
bool OpenPosition(int dir, double slPrice)
  {
   sym.RefreshRates();
   double price = (dir == DIR_BUY) ? sym.Ask() : sym.Bid();

   // --- Validate/adjust SL FIRST so the lot is sized off the REAL distance. ---
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopLevel * gPoint;

   if(dir == DIR_BUY)
     {
      if(slPrice >= price - minDist)
         slPrice = NormalizeDouble(price - minDist - gPoint, gDigits);
     }
   else
     {
      if(slPrice <= price + minDist)
         slPrice = NormalizeDouble(price + minDist + gPoint, gDigits);
     }

   // Now size the lot from the finalized entry price and SL.
   double lot = CalcLotByRisk(dir, price, slPrice);

   bool ok;
   if(dir == DIR_BUY)
      ok = trade.Buy(lot, _Symbol, 0.0, slPrice, 0.0, InpTradeComment);
   else
      ok = trade.Sell(lot, _Symbol, 0.0, slPrice, 0.0, InpTradeComment);

   if(!ok)
      PrintFormat("OpenPosition %s failed. lot=%.2f sl=%.5f err=%d",
                  (dir==DIR_BUY?"BUY":"SELL"), lot, slPrice, trade.ResultRetcode());
   else
      PrintFormat("Opened %s lot=%.2f SL=%.5f price=%.5f",
                  (dir==DIR_BUY?"BUY":"SELL"), lot, slPrice, price);
   return(ok);
  }

//+------------------------------------------------------------------+
//| Get the current shared SL across the basket (tightest = entry)   |
//|   For BUY  the basket SL is the HIGHEST sl among positions.      |
//|   For SELL the basket SL is the LOWEST  sl among positions.      |
//+------------------------------------------------------------------+
double CurrentBasketSL(int dir)
  {
   double result = 0.0;
   bool   found  = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagicNumber) continue;

      double sl = posInfo.StopLoss();
      if(sl == 0.0) continue;

      if(!found) { result = sl; found = true; continue; }

      if(dir == DIR_BUY)  result = MathMax(result, sl);
      else                result = MathMin(result, sl);
     }
   return(found ? result : 0.0);
  }

//+------------------------------------------------------------------+
//| Modify the SL of ALL basket positions to a common level          |
//+------------------------------------------------------------------+
void SetBasketSL(int dir, double newSL)
  {
   newSL = NormalizeDouble(newSL, gDigits);

   // Respect broker stop level relative to current price
   sym.RefreshRates();
   long   stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist   = stopLevel * gPoint;
   double bid = sym.Bid();
   double ask = sym.Ask();

   if(dir == DIR_BUY  && newSL >= bid - minDist) return; // can't set, too close
   if(dir == DIR_SELL && newSL <= ask + minDist) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagicNumber) continue;

      double curSL = posInfo.StopLoss();
      double curTP = posInfo.TakeProfit();

      if(MathAbs(curSL - newSL) < gPoint) continue; // already there

      if(!trade.PositionModify(ticket, newSL, curTP))
         PrintFormat("PositionModify failed ticket=%I64u newSL=%.5f err=%d",
                     ticket, newSL, trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//| Trail the basket SL to the just-closed candle hi/lo (shift=1)    |
//|   Only moves SL in the favorable direction (never loosens).      |
//+------------------------------------------------------------------+
void TrailBasketSL(int dir)
  {
   if(!InpTrailSL) return;

   double candidate = SLFromCandle(1, dir);   // hi/lo of last closed candle
   double current   = CurrentBasketSL(dir);

   bool improve;
   if(dir == DIR_BUY)
      improve = (current == 0.0) || (candidate > current);
   else
      improve = (current == 0.0) || (candidate < current);

   if(improve)
      SetBasketSL(dir, candidate);
  }

//+------------------------------------------------------------------+
//| Body ratio of a candle (body / full range) as percent 0..100     |
//+------------------------------------------------------------------+
double BodyRatioPercent(int shift)
  {
   double o = iOpen(_Symbol,  _Period, shift);
   double c = iClose(_Symbol, _Period, shift);
   double h = iHigh(_Symbol,  _Period, shift);
   double l = iLow(_Symbol,   _Period, shift);

   double range = h - l;
   if(range <= 0.0) return(0.0);
   double body = MathAbs(c - o);
   return(100.0 * body / range);
  }

//+------------------------------------------------------------------+
//| Decide whether the last closed candle is a valid "add" candle    |
//|   - Must be in the same color as the trade direction.            |
//|   - Body must be >= InpBodyRatioAdd % of its range.              |
//|   - Must extend further in trade direction (close beyond prior). |
//+------------------------------------------------------------------+
bool IsAddCandle(int dir)
  {
   if(!InpUsePyramiding) return(false);

   int candColor = CandleColor(1);             // last closed candle
   if(dir == DIR_BUY  && candColor != CC_GREEN) return(false);
   if(dir == DIR_SELL && candColor != CC_RED)   return(false);

   if(BodyRatioPercent(1) < InpBodyRatioAdd) return(false);

   // momentum continuation: candle 1 closes beyond candle 2 in trade dir
   double c1 = iClose(_Symbol, _Period, 1);
   double c2 = iClose(_Symbol, _Period, 2);
   if(dir == DIR_BUY  && !(c1 > c2)) return(false);
   if(dir == DIR_SELL && !(c1 < c2)) return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Main per-new-bar processing                                      |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   // --- Current basket state ---
   int dir = DIR_NONE;
   int openCount = CountPositions(dir);

   // Candle colors: 1 = last closed candle, 2 = the one before
   int color1 = CandleColor(1);
   int color2 = CandleColor(2);

   //================= MANAGE EXISTING BASKET =================//
   if(openCount > 0)
     {
      // 1) Sideways exit: close all on first YELLOW candle
      if(InpExitOnSideways && color1 == CC_YELLOW)
        {
         CloseAllPositions("sideways (yellow) candle");
         return;
        }

      // 2) Opposite color => trend flipped: close all (basket protection)
      if(dir == DIR_BUY && color1 == CC_RED)
        {
         CloseAllPositions("opposite (red) candle while long");
         return;
        }
      if(dir == DIR_SELL && color1 == CC_GREEN)
        {
         CloseAllPositions("opposite (green) candle while short");
         return;
        }

      // 3) Trend continues -> trail the shared basket SL
      TrailBasketSL(dir);


      // 4) Pyramiding: add a new position on strong continuation candle
      if(openCount < InpMaxPositions && IsAddCandle(dir))
        {
         double sl = SLFromCandle(1, dir);
         if(OpenPosition(dir, sl))
           {
            // After adding, sync the whole basket to the (trailed) SL
            if(InpUseSharedSL)
              {
               double bsl = CurrentBasketSL(dir);
               if(bsl != 0.0) SetBasketSL(dir, bsl);
              }
           }
        }
      return; // already in a trade; do not look for fresh entries
     }

   //==================== FRESH ENTRY SIGNALS ====================//
   // First GREEN candle => color1 GREEN and color2 not GREEN
   bool greenStart = (color1 == CC_GREEN && color2 != CC_GREEN);
   bool redStart   = (color1 == CC_RED   && color2 != CC_RED);

   if(greenStart)
     {
      double sl = SLFromCandle(1, DIR_BUY);
      OpenPosition(DIR_BUY, sl);
     }
   else if(redStart)
     {
      double sl = SLFromCandle(1, DIR_SELL);
      OpenPosition(DIR_SELL, sl);
     }
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Operate on bar close only (signals use closed candles).
   datetime curBarTime = iTime(_Symbol, _Period, 0);
   if(curBarTime == gLastBarTime)
      return;                       // not a new bar yet
   gLastBarTime = curBarTime;

   // Make sure indicators have enough data
   if(Bars(_Symbol, _Period) < InpEmaLength + 5)
      return;

   OnNewBar();
  }
//+------------------------------------------------------------------+
