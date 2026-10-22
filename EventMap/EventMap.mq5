//+------------------------------------------------------------------+
//|                                                     EventMap.mq5 |
//|                                                                  |
//|  WHAT IT DRAWS                                                   |
//|                                                                  |
//|   1. Scheduled news from the built-in MT5 economic calendar      |
//|      (importance, currency, exact release time).                 |
//|                                                                  |
//|   2. Recurring mechanical flow the calendar does not carry:      |
//|        - Tokyo 09:55 fix, WMR 16:00 London fix                   |
//|        - London / New York FX option cuts                        |
//|        - LBMA gold auctions, COMEX settlement                    |
//|        - Crypto perp funding, Deribit expiries, CME reopen       |
//|        - Month-end fix, quad witching, GSCI / IMM / LME rolls    |
//|                                                                  |
//|   3. Optional session open/close markers.                        |
//|                                                                  |
//|  READING THE CHART                                               |
//|      solid line  = scheduled news                                |
//|      dotted line = mechanical flow                               |
//|      purple line = monthly / quarterly event                     |
//|      thin grey   = session marker                                |
//|      hover a line for the full description.                      |
//|                                                                  |
//|  NOTES                                                           |
//|      - Flow times are computed in UTC, then shifted to the       |
//|        broker server clock, so they line up with your bars.      |
//|      - US and EU daylight saving rules are applied per date.     |
//|      - News is not available in the Strategy Tester; the tester  |
//|        will show flow events only.                               |
//+------------------------------------------------------------------+
#property copyright "EventMap"
#property version   "1.00"
#property description "Scheduled news + recurring mechanical flow, drawn on the chart."
#property description "Solid = news, dotted = flow, purple = monthly, grey = session."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//==================================================================
//  INPUTS
//==================================================================
enum EMAP_IMP
  {
   EMAP_ALL   = 0,   // All
   EMAP_LOW   = 1,   // Low and above
   EMAP_MED   = 2,   // Medium and above
   EMAP_HIGH  = 3    // High only
  };

input group "=== News (MT5 calendar) ==="
input bool        InpShowNews           = true;        // Draw scheduled news
input EMAP_IMP    InpMinImportance      = EMAP_MED;    // Minimum importance to draw
input bool        InpFilterSymbol       = true;        // Only events for this symbol's currencies
input string      InpExtraCurrencies    = "";          // Always include these, e.g. "EUR,GBP"
input int         InpPastDays           = 10;          // Days of history to draw
input int         InpFutureDays         = 0;           // Days ahead to draw
input int         InpRefreshMinutes     = 15;          // Re-read the calendar every N minutes (0 = new bar only)
input int         InpCalendarShiftMin   = 0;           // Shift news times, minutes (if your feed is offset)

input group "=== Mechanical flow ==="
input bool        InpShowFlow           = false;       // Draw recurring flow events
input bool        InpFlowFxFix          = true;        // Tokyo 09:55 + WMR 16:00 London fix
input bool        InpFlowOptionCut      = true;        // London / New York option cuts
input bool        InpFlowMetals         = true;        // LBMA auctions + COMEX settlement
input bool        InpFlowCrypto         = true;        // Funding, Deribit expiry, CME reopen
input bool        InpFlowMonthly        = true;        // Month-end fix, quad witching, rolls
input bool        InpShowSessions       = true;        // Tokyo / London / NY session markers

input group "=== External feed (CSV) ==="
input bool        InpUseCsv             = true;        // Read the external feed written by fetch_events.ps1
input string      InpCsvFile            = "EventMap\\events.csv"; // Feed path inside MQL5\Files
input int         InpCsvWarnHours       = 12;          // Flag the feed as stale after N hours (0 = never)
input bool        InpSrcFf              = true;        // Forex Factory rows
input bool        InpSrcInvesting       = true;        // Investing.com rows

input group "=== Style ==="
input color       InpNewsHighColor      = clrTomato;      // High-impact news
input color       InpNewsMedColor       = clrOrange;      // Medium-impact news
input color       InpNewsLowColor       = clrDimGray;     // Low-impact news
input color       InpFlowColor          = clrDodgerBlue;  // Daily flow
input color       InpMonthlyColor       = clrMediumPurple;// Monthly / quarterly flow
input color       InpSessionColor       = clrSlateGray;   // Session markers
input int         InpLineWidth          = 1;              // Line width
input bool        InpShowLabels         = false;          // Text labels at the top of the chart
input int         InpLabelFontSize      = 7;              // Label font size
input int         InpMinLabelImp        = 2;              // Min importance for a label (0-3)
input double      InpLabelTopPct        = 4.0;            // Label band, % from the top of the chart
input bool        InpLabelsVertical     = false;          // Rotate labels 90 degrees

input group "=== Panel ==="
input bool        InpShowPanel          = true;           // Show the upcoming-events panel
input int         InpPanelRows          = 8;              // Rows of upcoming events
input int         InpPanelFontSize      = 9;              // Panel font size
input int         InpPanelWidth         = 350;            // Panel width, px
input ENUM_BASE_CORNER InpPanelCorner   = CORNER_LEFT_UPPER; // Panel corner
input int         InpPanelX             = 12;             // Panel X offset, px
input int         InpPanelY             = 24;             // Panel Y offset, px

input group "=== Alerts ==="
input bool        InpAlertPopup         = false;          // Popup alert
input bool        InpAlertSound         = false;          // Play sound
input bool        InpAlertPush          = false;          // Push notification to phone
input int         InpAlertMinutesBefore = 15;             // Alert this many minutes before (0 = off)

input group "=== Diagnostics ==="
input int         InpServerOffsetMin    = 9999;           // Server GMT offset in minutes (9999 = auto)
input bool        InpVerbose            = false;          // Journal logging

//==================================================================
//  CONSTANTS AND STATE
//==================================================================
#define EMAP_MAX      4096
#define EMAP_K_NEWS   0
#define EMAP_K_FLOW   1
#define EMAP_K_MONTH  2
#define EMAP_K_SESS   3

#define EMAP_PFX_LINE "EMAP_L_"
#define EMAP_PFX_TEXT "EMAP_T_"
#define EMAP_PFX_ROW  "EMAP_P_ROW_"
#define EMAP_PFX_INFO "EMAP_INFO_"

int        g_scroll       = -1;   // panel scroll base, -1 = follow current time
int        g_panelW       = 0;    // measured panel width
int        g_listTotal    = 0;    // panel list length (groups)
int        g_listFollow   = -1;   // index of first upcoming group

// vertical scrollbar geometry, filled in during panel rendering
int        g_sbTrackX     = 0;
int        g_sbTrackY     = 0;
int        g_sbTrackH     = 0;
int        g_sbThumbH     = 0;
int        g_sbMax        = 0;    // total - InpPanelRows; 0 = scrollbar hidden
bool       g_sbDrag       = false;

struct EmapEvent
  {
   datetime          t;        // server time
   string            title;
   string            cur;
   int               imp;      // 0-3, 3 = high
   int               kind;     // EMAP_K_*
   string            uid;      // dedupe / alert key
   string            src;      // provider: ff, investing, cal...
  };

EmapEvent  g_ev[];
int        g_nEv         = 0;
bool       g_calOk       = false;
bool       g_refreshed   = false;
string     g_alerted[];
int        g_nAlerted    = 0;

string     g_srcList     = "";    // summary: "ff 62 + inv 341"

// external feed state
bool       g_csvOk       = false;
int        g_csvRows     = 0;
int        g_csvAgeMin   = -1;

//==================================================================
//  SMALL UTILITIES
//==================================================================
bool EmapIsLeap(const int y)
  {
   return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0);
  }

int EmapDaysInMonth(const int y,const int m)
  {
   int d[12] = {31,28,31,30,31,30,31,31,30,31,30,31};
   if(m < 1 || m > 12)
      return 30;
   if(m == 2 && EmapIsLeap(y))
      return 29;
   return d[m-1];
  }

datetime EmapMakeUTC(const int y,const int m,const int d,const int hh,const int mi)
  {
   MqlDateTime s;
   s.year = y; s.mon = m; s.day = d; s.hour = hh; s.min = mi; s.sec = 0;
   s.day_of_week = 0; s.day_of_year = 0;
   return StructToTime(s);
  }

int EmapDow(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return s.day_of_week;
  }

datetime EmapDayStart(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return EmapMakeUTC(s.year,s.mon,s.day,0,0);
  }

string EmapDowName(const int d)
  {
   string n[7] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   if(d < 0 || d > 6)
      return "???";
   return n[d];
  }

string EmapHM(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return StringFormat("%02d:%02d",s.hour,s.min);
  }

string EmapDayHM(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return StringFormat("%s %02d:%02d",EmapDowName(s.day_of_week),s.hour,s.min);
  }

// dd/mm/yyyy HH:MM (panel rows)
string EmapDateHM(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return StringFormat("%02d/%02d/%04d %02d:%02d",s.day,s.mon,s.year,s.hour,s.min);
  }

// draw window: what actually gets VISIBLE on the chart (lines + labels).
// The calendar/CSV loaders can carry a wider range; InpFutureDays = 0 means
// "draw today only" (through end of day), not "draw up to this very second".
void EmapDrawWindow(datetime &from,datetime &to)
  {
   datetime now = TimeCurrent();
   from = EmapDayStart(now) - (datetime)(InpPastDays   * 86400);
   to   = EmapDayStart(now) + (datetime)((InpFutureDays + 1) * 86400) - 1;
  }

string EmapTrunc(const string src,const int maxlen)
  {
   if(StringLen(src) <= maxlen)
      return src;
   return StringSubstr(src,0,maxlen-2) + "..";
  }

// "2026-10-21T07:26:42Z" -> UTC datetime (0 on failure)
datetime EmapParseIsoZ(const string s)
  {
   if(StringLen(s) < 19)
      return 0;
   int y  = (int)StringToInteger(StringSubstr(s,0,4));
   int mo = (int)StringToInteger(StringSubstr(s,5,2));
   int d  = (int)StringToInteger(StringSubstr(s,8,2));
   int hh = (int)StringToInteger(StringSubstr(s,11,2));
   int mi = (int)StringToInteger(StringSubstr(s,14,2));
   int ss = (int)StringToInteger(StringSubstr(s,17,2));
   if(y < 2000 || mo < 1 || mo > 12 || d < 1 || d > 31)
      return 0;
   return EmapMakeUTC(y,mo,d,hh,mi) + (datetime)ss;
  }

// First day-of-month for the nth given weekday. dow: 0=Sun .. 6=Sat
int EmapNthWeekdayDay(const int y,const int m,const int dow,const int nth)
  {
   int first = EmapDow(EmapMakeUTC(y,m,1,0,0));
   int day   = 1 + ((dow - first + 7) % 7) + (nth - 1) * 7;
   if(day > EmapDaysInMonth(y,m))
      return 0;
   return day;
  }

int EmapLastWeekdayDay(const int y,const int m,const int dow)
  {
   int dim = EmapDaysInMonth(y,m);
   int wd  = EmapDow(EmapMakeUTC(y,m,dim,0,0));
   return dim - ((wd - dow + 7) % 7);
  }

// US DST: 2nd Sunday March 02:00 local -> 07:00 UTC, ends 1st Sunday Nov 02:00 local -> 06:00 UTC
bool EmapUSDST(const datetime utc)
  {
   MqlDateTime s;
   TimeToStruct(utc,s);
   int d1 = EmapNthWeekdayDay(s.year,3,0,2);
   int d2 = EmapNthWeekdayDay(s.year,11,0,1);
   if(d1 == 0 || d2 == 0)
      return false;
   datetime start = EmapMakeUTC(s.year,3, d1,7,0);
   datetime end   = EmapMakeUTC(s.year,11,d2,6,0);
   return (utc >= start && utc < end);
  }

// EU DST: last Sunday March 01:00 UTC -> last Sunday October 01:00 UTC
bool EmapEUDST(const datetime utc)
  {
   MqlDateTime s;
   TimeToStruct(utc,s);
   int d1 = EmapLastWeekdayDay(s.year,3,0);
   int d2 = EmapLastWeekdayDay(s.year,10,0);
   datetime start = EmapMakeUTC(s.year,3, d1,1,0);
   datetime end   = EmapMakeUTC(s.year,10,d2,1,0);
   return (utc >= start && utc < end);
  }

datetime EmapLondonToUTC(const int y,const int m,const int d,const int hh,const int mi)
  {
   datetime approx = EmapMakeUTC(y,m,d,hh,mi);
   if(EmapEUDST(approx))
      approx -= 3600;
   return approx;
  }

datetime EmapNYToUTC(const int y,const int m,const int d,const int hh,const int mi)
  {
   datetime approx = EmapMakeUTC(y,m,d,hh,mi);
   if(EmapUSDST(approx))
      approx += 4 * 3600;
   else
      approx += 5 * 3600;
   return approx;
  }

long EmapServerOffset()
  {
   if(InpServerOffsetMin != 9999)
      return (long)InpServerOffsetMin * 60;
   return (long)(TimeTradeServer() - TimeGMT());
  }

// 1-based count of weekdays so far in the month (Mon-Fri only)
int EmapBizDayIndex(const int y,const int m,const int d)
  {
   int c = 0;
   for(int i = 1; i <= d; i++)
     {
      int wd = EmapDow(EmapMakeUTC(y,m,i,0,0));
      if(wd != 0 && wd != 6)
         c++;
     }
   return c;
  }

bool EmapIsLastBizDay(const int y,const int m,const int d)
  {
   int dim = EmapDaysInMonth(y,m);
   for(int i = d + 1; i <= dim; i++)
     {
      int wd = EmapDow(EmapMakeUTC(y,m,i,0,0));
      if(wd != 0 && wd != 6)
         return false;
     }
   return true;
  }

//==================================================================
//  EVENT STORE
//==================================================================
void EmapAdd(const datetime t,const string title,const string cur,
             const int imp,const int kind,const string uid,
             const string src="")
  {
   if(g_nEv >= EMAP_MAX)
      return;
   for(int i = 0; i < g_nEv; i++)
     {
      if(g_ev[i].t == t && g_ev[i].title == title)
         return;                     // duplicate
     }
   g_ev[g_nEv].t     = t;
   g_ev[g_nEv].title = title;
   g_ev[g_nEv].cur   = cur;
   g_ev[g_nEv].imp   = imp;
   g_ev[g_nEv].kind  = kind;
   g_ev[g_nEv].uid   = uid;
   g_ev[g_nEv].src   = src;
   g_nEv++;
  }

void EmapSort()
  {
   for(int i = 1; i < g_nEv; i++)
     {
      EmapEvent key = g_ev[i];
      int j = i - 1;
      while(j >= 0 && g_ev[j].t > key.t)
        {
         g_ev[j+1] = g_ev[j];
         j--;
        }
      g_ev[j+1] = key;
     }
  }

// Events that land on the same minute from different sources are one
// market moment, not several. They share a line, a label and a panel row.
int EmapGroupEnd(const int start)
  {
   int i = start + 1;
   while(i < g_nEv &&
         g_ev[i].kind == g_ev[start].kind &&
         (long)(g_ev[i].t - g_ev[start].t) <= 60)
      i++;
   return i;
  }

int EmapBestInGroup(const int start,const int end)
  {
   int best = start;
   for(int i = start + 1; i < end; i++)
      if(g_ev[i].imp > g_ev[best].imp)
         best = i;
   return best;
  }

color EmapColor(const EmapEvent &e)
  {
   if(e.kind == EMAP_K_SESS)  return InpSessionColor;
   if(e.kind == EMAP_K_MONTH) return InpMonthlyColor;
   if(e.kind == EMAP_K_FLOW)  return InpFlowColor;
   if(e.imp >= 3)             return InpNewsHighColor;
   if(e.imp == 2)             return InpNewsMedColor;
   return InpNewsLowColor;
  }

ENUM_LINE_STYLE EmapStyle(const EmapEvent &e)
  {
   if(e.kind == EMAP_K_NEWS)
      return STYLE_SOLID;
   if(e.kind == EMAP_K_MONTH)
      return STYLE_DASH;
   return STYLE_DOT;
  }

int EmapWidth(const EmapEvent &e)
  {
   int w = InpLineWidth;
   if(e.kind == EMAP_K_MONTH)
      w = InpLineWidth + 1;
   if(e.kind == EMAP_K_SESS)
      w = 1;
   if(w < 1)
      w = 1;
   return w;
  }

string EmapTag(const EmapEvent &e)
  {
   if(e.kind == EMAP_K_SESS)  return "S";
   if(e.kind == EMAP_K_MONTH) return "M*";
   if(e.kind == EMAP_K_FLOW)  return "F";
   if(e.imp >= 3)             return "H";
   if(e.imp == 2)             return "M";
   return "L";
  }

string EmapImpName(const int imp)
  {
   if(imp >= 3) return "high";
   if(imp == 2) return "medium";
   if(imp == 1) return "low";
   return "flow";
  }

string EmapSrcFull(const string s)
  {
   if(s == "ff")  return "ForexFactory";
   if(s == "inv") return "Investing.com";
   if(s == "cal") return "MT5 calendar";
   if(s == "tv")  return "TradingView";
   return s;
  }

string EmapTooltip(const EmapEvent &e)
  {
   string t = EmapDayHM(e.t);
   string c = (e.cur == "") ? "" : e.cur + " ";
   string p = (e.src == "") ? "" : ", " + e.src;
   return StringFormat("%s  %s%s  [%s%s]",t,c,e.title,EmapImpName(e.imp),p);
  }

string EmapGroupTooltip(const int start,const int end)
  {
   int    best  = EmapBestInGroup(start,end);
   string s     = EmapTooltip(g_ev[best]);
   int    extra = end - start - 1;
   if(extra > 0)
     {
      s += StringFormat("   (+%d same minute)",extra);
      int shown = 0;
      for(int i = start; i < end && shown < 5; i++)
        {
         if(i == best)
            continue;
         s += "\n  - " + g_ev[i].title;
         shown++;
        }
     }
   return s;
  }

// multi-line text used for BOTH the hover tooltip and the click popup:
// every event in the group, one line each, full time/currency/importance
string EmapGroupInfoText(const int start,const int end)
  {
   string s = "";
   for(int i = start; i < end; i++)
      s += (s == "" ? "" : "\n") + EmapTooltip(g_ev[i]);
   if(end - start > 1)
      s += StringFormat("\n(+%d more recorded at this time)",end - start - 1);
   return s;
  }

//==================================================================
//  FLOW BUILDER  (everything the calendar does not carry)
//==================================================================
void EmapBuildFlow()
  {
   if(!InpShowFlow)
      return;

   long     off     = EmapServerOffset();
   datetime nowUtc  = TimeCurrent() - (datetime)off;
   datetime fromUtc = nowUtc - (datetime)(InpPastDays   * 86400);
   datetime toUtc   = nowUtc + (datetime)(InpFutureDays * 86400);

   for(datetime day = EmapDayStart(fromUtc); day <= toUtc; day += (datetime)86400)
     {
      MqlDateTime s;
      TimeToStruct(day,s);
      int  y  = s.year, m = s.mon, d = s.day;
      bool wd = (s.day_of_week != 0 && s.day_of_week != 6);

      //--- crypto runs every day -------------------------------------
      if(InpFlowCrypto)
        {
         for(int h = 0; h < 24; h += 8)
            EmapAdd(EmapMakeUTC(y,m,d,h,0) + off,
                    StringFormat("Perp funding %02d:00 UTC",h),"",1,EMAP_K_FLOW,
                    "fund_" + IntegerToString(h));

         bool quarterly = ((m == 3 || m == 6 || m == 9 || m == 12) &&
                           s.day_of_week == 5 && EmapLastWeekdayDay(y,m,5) == d);
         if(quarterly)
            EmapAdd(EmapMakeUTC(y,m,d,8,0) + off,"Deribit quarterly expiry","",3,EMAP_K_MONTH,"deribit_q");
         else if(s.day_of_week == 5)
            EmapAdd(EmapMakeUTC(y,m,d,8,0) + off,"Deribit weekly expiry","",2,EMAP_K_FLOW,"deribit_w");

         if(s.day_of_week == 0)
            EmapAdd(EmapNYToUTC(y,m,d,18,0) + off,"CME crypto reopen","",1,EMAP_K_FLOW,"cme_open");
        }

      if(!wd)
         continue;

      //--- FX fixes -------------------------------------------------
      if(InpFlowFxFix)
        {
         EmapAdd(EmapMakeUTC(y,m,d,0,55) + off,"Tokyo 09:55 fix","JPY",2,EMAP_K_FLOW,"fx_tokyo");

         bool monthEnd = EmapIsLastBizDay(y,m,d);
         EmapAdd(EmapLondonToUTC(y,m,d,16,0) + off,
                 monthEnd ? "Month-end WMR fix" : "WMR 16:00 London fix",
                 "", monthEnd ? 3 : 2,
                 monthEnd ? EMAP_K_MONTH : EMAP_K_FLOW,
                 monthEnd ? "fx_wmr_me" : "fx_wmr");
        }

      if(InpFlowOptionCut)
        {
         EmapAdd(EmapLondonToUTC(y,m,d,10,0) + off,"FX option cut (London)","",1,EMAP_K_FLOW,"cut_ldn");
         EmapAdd(EmapNYToUTC(y,m,d,10,0) + off,"FX option cut (New York)","",1,EMAP_K_FLOW,"cut_ny");
        }

      //--- metals ---------------------------------------------------
      if(InpFlowMetals)
        {
         EmapAdd(EmapLondonToUTC(y,m,d,10,30) + off,"LBMA gold auction (AM)","XAU",1,EMAP_K_FLOW,"xau_am");
         EmapAdd(EmapLondonToUTC(y,m,d,15,0)  + off,"LBMA gold auction (PM)","XAU",1,EMAP_K_FLOW,"xau_pm");
         EmapAdd(EmapNYToUTC(y,m,d,13,30)     + off,"COMEX settlement","",1,EMAP_K_FLOW,"comex");
        }

      //--- sessions -------------------------------------------------
      if(InpShowSessions)
        {
         EmapAdd(EmapMakeUTC(y,m,d,0,0)      + off,"Tokyo open","",1,EMAP_K_SESS,"ses_tokyo");
         EmapAdd(EmapLondonToUTC(y,m,d,8,0)  + off,"London open","",1,EMAP_K_SESS,"ses_ldn");
         EmapAdd(EmapLondonToUTC(y,m,d,17,0) + off,"London close","",1,EMAP_K_SESS,"ses_ldnc");
         EmapAdd(EmapNYToUTC(y,m,d,9,30)     + off,"New York equity open","",1,EMAP_K_SESS,"ses_ny");
         EmapAdd(EmapNYToUTC(y,m,d,16,0)     + off,"New York close","",1,EMAP_K_SESS,"ses_nyc");
        }

      //--- monthly / quarterly --------------------------------------
      if(InpFlowMonthly)
        {
         int bd = EmapBizDayIndex(y,m,d);
         if(bd >= 5 && bd <= 9)
            EmapAdd(EmapMakeUTC(y,m,d,0,0) + off,"GSCI roll window","",1,EMAP_K_MONTH,"gsci_roll");

         if(s.day_of_week == 3 && d >= 15 && d <= 21)
            EmapAdd(EmapLondonToUTC(y,m,d,12,30) + off,"LME prompt date / IMM roll","",2,EMAP_K_MONTH,"lme_imm");

         if((m == 3 || m == 6 || m == 9 || m == 12) &&
            s.day_of_week == 5 && d >= 15 && d <= 21)
            EmapAdd(EmapNYToUTC(y,m,d,16,0) + off,"Quad witching","",3,EMAP_K_MONTH,"quad");
        }
     }
  }

//==================================================================
//  NEWS BUILDER  (built-in calendar)
//==================================================================
bool EmapCurWanted(const string cur)
  {
   if(!InpFilterSymbol || cur == "")
      return true;

   if(StringFind("," + InpExtraCurrencies + ",","," + cur + ",") >= 0)
      return true;

   string majors[8] = {"USD","EUR","GBP","JPY","CHF","CAD","AUD","NZD"};
   bool   found = false;
   for(int i = 0; i < 8; i++)
     {
      if(StringFind(_Symbol,majors[i]) >= 0)
        {
         found = true;
         if(majors[i] == cur)
            return true;
        }
     }
   if(!found)
      return (cur == "USD");           // indices / metals / crypto quote in USD
   return false;
  }

void EmapBuildNews()
  {
   g_calOk = false;
   if(!InpShowNews)
      return;

   // end-of-day inclusive: InpFutureDays = 0 keeps the rest of today loaded
   datetime from = EmapDayStart(TimeCurrent()) - (datetime)(InpPastDays   * 86400);
   datetime to   = EmapDayStart(TimeCurrent()) + (datetime)((InpFutureDays + 1) * 86400) - 1;

   MqlCalendarValue vals[];
   int n = CalendarValueHistory(vals,from,to,NULL,NULL);
   if(n <= 0)
     {
      if(InpVerbose)
         Print("EventMap: calendar returned no values (offline, or running in the tester)");
      return;
     }
   g_calOk = true;

   int added = 0;
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id,ev))
         continue;

      int imp = (int)ev.importance;
      if(imp < (int)InpMinImportance)
         continue;

      string cur = "";
      MqlCalendarCountry c;
      if(CalendarCountryById(ev.country_id,c))
         cur = c.currency;

      if(!EmapCurWanted(cur))
         continue;

      datetime t = vals[i].time + (datetime)(InpCalendarShiftMin * 60);
      string   title = (cur == "") ? ev.name : cur + " " + ev.name;
      if(StringLen(ev.name) == 0)
         title = "Calendar event";

      EmapAdd(t,title,cur,imp,EMAP_K_NEWS,"cal_" + IntegerToString((long)vals[i].id),"cal");
      added++;
     }

   if(InpVerbose)
      PrintFormat("EventMap: %d calendar values in window, %d added",n,added);
  }

//==================================================================
//  EXTERNAL FEED  (fetch_events.ps1 output)
//==================================================================
void EmapBuildCsv()
  {
   g_csvOk     = false;
   g_csvRows   = 0;
   g_csvAgeMin = -1;
   g_srcList   = "";
   string srcNames[8]; int srcCnt[8]; int nSrc = 0;
   for(int i = 0; i < 8; i++)
      { srcNames[i] = ""; srcCnt[i] = 0; }
   if(!InpUseCsv)
      return;

   int h = FileOpen(InpCsvFile,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
     {
      if(InpVerbose)
         PrintFormat("EventMap: no external feed at %s (error %d)",InpCsvFile,GetLastError());
      return;
     }

   long     off       = EmapServerOffset();
   datetime generated = 0;

   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0)
         continue;

      if(StringGetCharacter(line,0) == '#')
        {
         int p = StringFind(line,"generated=");
         if(p >= 0)
            generated = EmapParseIsoZ(StringSubstr(line,p + 10,20));
         continue;
        }
      if(StringFind(line,"epoch|") == 0)
         continue;

      string f[];
      if(StringSplit(line,(ushort)'|',f) != 8)
         continue;

      datetime utc = (datetime)StringToInteger(f[0]);
      if(utc < 1000000000)
         continue;

      // provider toggles: user decides which feeds are drawn
      if((f[7] == "ff" && !InpSrcFf) ||
         (f[7] == "investing" && !InpSrcInvesting))
         continue;
      if(f[7] != "ff" && f[7] != "investing")
         continue;                    // legacy tv / unknown

      // keep the currency filter for the feed rows too: the user wants
      // chart AND panel to show only the pair's currencies
      if(!EmapCurWanted(f[1]))
         continue;

      string title = f[3];
      if(StringLen(title) == 0)
         continue;

      int imp = 1;
      if(f[2] == "high")
         imp = 3;
      else if(f[2] == "medium")
         imp = 2;

      string uid = "csv_" + f[7] + "_" + IntegerToString((long)utc) + "_" + f[1];
      string srcName = (f[7] == "investing") ? "inv" : f[7];
      bool srcKnown = false;
      for(int s = 0; s < nSrc; s++)
         if(srcNames[s] == srcName)
            { srcCnt[s]++; srcKnown = true; break; }
      if(!srcKnown && nSrc < 8)
         { srcNames[nSrc] = srcName; srcCnt[nSrc]++; nSrc++; }
      EmapAdd(utc + (datetime)off,title,f[1],imp,EMAP_K_NEWS,uid,srcName);
      g_csvRows++;
     }
   FileClose(h);

   g_csvOk = (g_csvRows > 0);
   for(int s = 0; s < nSrc; s++)
      g_srcList += (s == 0 ? "" : " + ") +
                   StringFormat("%s %d",EmapSrcFull(srcNames[s]),srcCnt[s]);
   if(generated > 0)
      g_csvAgeMin = (int)(((TimeCurrent() - (datetime)off) - generated) / 60);

   if(InpVerbose)
      PrintFormat("EventMap: external feed %d rows, generated %s (%d min ago)",
                  g_csvRows,
                  generated > 0 ? TimeToString(generated,TIME_DATE|TIME_MINUTES) : "unknown",
                  g_csvAgeMin);
  }

//==================================================================
//  REFRESH
//==================================================================
void EmapRefresh()
  {
   for(int i = 0; i < g_nEv; i++)
     {
      g_ev[i].title = "";
      g_ev[i].cur   = "";
      g_ev[i].uid   = "";
      g_ev[i].src   = "";
     }
   g_nEv = 0;

   EmapBuildFlow();
   EmapBuildCsv();
   EmapBuildNews();
   EmapSort();
   g_refreshed = true;

   if(InpVerbose)
      PrintFormat("EventMap: %d events cached, server offset %+d min",
                  g_nEv,(int)(EmapServerOffset() / 60));
  }

//==================================================================
//  DRAWING
//==================================================================
void EmapDrawLines()
  {
   ObjectsDeleteAll(0,EMAP_PFX_LINE);
   ObjectsDeleteAll(0,EMAP_PFX_INFO);
   if(!g_refreshed)
      return;

   datetime drawFrom,drawTo;
   EmapDrawWindow(drawFrom,drawTo);

   int idx = 0;
   for(int i = 0; i < g_nEv; )
     {
      int end  = EmapGroupEnd(i);
      int best = EmapBestInGroup(i,end);

      // honour InpMinImportance here - centrally, not per source. Both loaders
      // apply the symbol-currency filter (EmapCurWanted), and the panel now
      // applies the same importance filter in its own catalogue (a panel row
      // is drawn only if its most important member passes the filter).
      if(g_ev[best].imp < (int)InpMinImportance)
        {
         i = end;
         continue;
        }

      // future/past drawing window (InpFutureDays = 0 -> today only)
      if(g_ev[best].t < drawFrom || g_ev[best].t > drawTo)
        {
         i = end;
         continue;
        }

      string info = EmapGroupInfoText(i,end);
      string nm = EMAP_PFX_LINE + IntegerToString(idx++);
      if(ObjectCreate(0,nm,OBJ_VLINE,0,g_ev[i].t,0))
        {
         ObjectSetInteger(0,nm,OBJPROP_COLOR,EmapColor(g_ev[best]));
         ObjectSetInteger(0,nm,OBJPROP_STYLE,EmapStyle(g_ev[best]));
         ObjectSetInteger(0,nm,OBJPROP_WIDTH,EmapWidth(g_ev[best]));
         ObjectSetInteger(0,nm,OBJPROP_BACK,true);
         ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
         ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
         ObjectSetString(0,nm,OBJPROP_TOOLTIP,info);
         ObjectSetString(0,nm,OBJPROP_TEXT,info);   // stashed for the click popup
        }
      i = end;
     }
  }

void EmapDrawLabels()
  {
   ObjectsDeleteAll(0,EMAP_PFX_TEXT);
   if(!InpShowLabels || !g_refreshed)
      return;

   double hi = ChartGetDouble(0,CHART_PRICE_MAX,0);
   double lo = ChartGetDouble(0,CHART_PRICE_MIN,0);
   if(hi <= lo)
      return;

   double rng = hi - lo;
   double top = hi - rng * (InpLabelTopPct / 100.0);

   datetime lastT = 0;
   int      level = 0;
   int      idx   = 0;

   datetime drawFrom,drawTo;
   EmapDrawWindow(drawFrom,drawTo);

   for(int i = 0; i < g_nEv; )
     {
      int start = i;
      int end  = EmapGroupEnd(start);
      int best = EmapBestInGroup(start,end);
      int extra = end - start - 1;
      i = end;

      if(g_ev[best].kind == EMAP_K_SESS)
         continue;
      if(g_ev[best].imp < InpMinLabelImp)
         continue;
      if(g_ev[best].t < drawFrom || g_ev[best].t > drawTo)
         continue;

      bool stacked = (lastT != 0 && (long)(g_ev[best].t - lastT) < (long)(3 * PeriodSeconds()));
      level = stacked ? ((level < 6) ? level + 1 : 6) : 0;

      string nm = EMAP_PFX_TEXT + IntegerToString(idx++);
      double price = top - rng * 0.045 * level;

      if(!ObjectCreate(0,nm,OBJ_TEXT,0,g_ev[best].t,price))
         continue;
      string label = g_ev[best].title;
      if(g_ev[best].kind == EMAP_K_MONTH)
         label = "* " + label;
      if(extra > 0)
         label += StringFormat(" +%d",extra);
      ObjectSetString(0,nm,OBJPROP_TEXT,EmapTrunc(label,24));
      ObjectSetString(0,nm,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,InpLabelFontSize);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,EmapColor(g_ev[best]));
      ObjectSetInteger(0,nm,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetDouble(0,nm,OBJPROP_ANGLE,InpLabelsVertical ? 90.0 : 0.0);
      ObjectSetInteger(0,nm,OBJPROP_BACK,false);
      ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
      ObjectSetString(0,nm,OBJPROP_TOOLTIP,EmapGroupTooltip(start,end));

      lastT = g_ev[best].t;
     }
  }

//==================================================================
//  CLICK POPUP  (info shown when a line is clicked)
//==================================================================
// one Consolas glyph at the panel font size, incl. DPI scale: the terminal
// renders label fonts scaled to the screen DPI, so TextGetSize() (96-dpi
// metrics) under-measures. Consolas advance is ~0.55em = 0.733*fs px at
// 96dpi; 0.75*fs never under-estimates.
int EmapCharW()
  {
   double k = (double)TerminalInfoInteger(TERMINAL_SCREEN_DPI) / 96.0;
   if(k < 1.0)
      k = 1.0;
   return (int)MathCeil(0.75 * InpPanelFontSize * k);
  }

int EmapTextW(const string text)
  {
   return StringLen(text) * EmapCharW();
  }

void EmapInfoHide()
  {
   ObjectsDeleteAll(0,EMAP_PFX_INFO);
  }

void EmapInfoShow(const string lineName,int mouse_x,int mouse_y)
  {
   string info = ObjectGetString(0,lineName,OBJPROP_TEXT);
   if(StringLen(info) == 0)
      return;
   string parts[];
   if(StringSplit(info,(ushort)'\n',parts) < 1)
      return;

   EmapInfoHide();

   int rowh = InpPanelFontSize + 6;
   int wpx  = 0;
   for(int k = 0; k < ArraySize(parts); k++)
      wpx = MathMax(wpx,EmapTextW(parts[k]));
   wpx = MathMax(wpx + 24,200);

   int hpx = (ArraySize(parts) + 1) * rowh + 10;
   int cw  = (int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
   int ch  = (int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   int x  = (int)MathMax(10,MathMin(mouse_x,cw - wpx - 10));
   int y  = (int)MathMax(10,MathMin(mouse_y,ch - hpx - 10));

   string bg = (string)EMAP_PFX_INFO + "BG";
   if(ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0))
     {
      ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,bg,OBJPROP_XSIZE,wpx);
      ObjectSetInteger(0,bg,OBJPROP_YSIZE,hpx);
      ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'18,20,26');
      ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,bg,OBJPROP_COLOR,C'120,140,190');
      ObjectSetInteger(0,bg,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,bg,OBJPROP_BACK,false);
      ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,bg,OBJPROP_ZORDER,90);
     }

   for(int k = 0; k < ArraySize(parts); k++)
     {
      string nm = (string)EMAP_PFX_INFO + IntegerToString(k);
      if(ObjectCreate(0,nm,OBJ_LABEL,0,0,0))
        {
         ObjectSetInteger(0,nm,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x + 10);
         ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y + 5 + k * rowh);
         ObjectSetString(0,nm,OBJPROP_TEXT,parts[k]);
         ObjectSetString(0,nm,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,InpPanelFontSize);
         ObjectSetInteger(0,nm,OBJPROP_COLOR,k == 0 ? clrSilver : clrWhite);
         ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
         ObjectSetInteger(0,nm,OBJPROP_BACK,false);
         ObjectSetInteger(0,nm,OBJPROP_ZORDER,91);
        }
     }
  }

//==================================================================
//  PANEL
//==================================================================
int EmapRowH()
  {
   return InpPanelFontSize + 8;
  }

void EmapPanelRow(const int idx,const string text,const color clr,const bool bold)
  {
   string nm = EMAP_PFX_ROW + IntegerToString(idx);
   if(ObjectFind(0,nm) < 0)
      ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,nm,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,InpPanelX + 8);
   ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,InpPanelY + 5 + idx * EmapRowH());
   ObjectSetString(0,nm,OBJPROP_TEXT,text);
   ObjectSetString(0,nm,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,InpPanelFontSize);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,nm,OBJPROP_BACK,false);
  }

// one cell of an event row: separate OBJ_LABEL so the columns align
void EmapPanelCell(const int idx,const string part,const int x,const string text,const color clr)
  {
   string nm = EMAP_PFX_ROW + IntegerToString(idx) + part;
   if(ObjectFind(0,nm) < 0)
      ObjectCreate(0,nm,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,nm,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,InpPanelY + 5 + idx * EmapRowH());
   ObjectSetString(0,nm,OBJPROP_TEXT,text);
   ObjectSetString(0,nm,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,InpPanelFontSize);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,nm,OBJPROP_BACK,false);
  }

// an event row is FOUR labels in fixed-width columns:
//   A: date+time   B: tag   C: currency   D: full title
void EmapPanelEventRow(const int idx,const string timeText,const string tagText,
                       const string curText,const string ttlText,const color clr)
  {
   int cw = EmapCharW();
   EmapPanelCell(idx,"A",InpPanelX + 8,          timeText,clr);
   EmapPanelCell(idx,"B",InpPanelX + 8 + 17 * cw,tagText,clr);
   EmapPanelCell(idx,"C",InpPanelX + 8 + 24 * cw,curText,clr);
   EmapPanelCell(idx,"D",InpPanelX + 8 + 29 * cw,ttlText,clr);
  }

void EmapPanelCreate()
  {
   if(!InpShowPanel)
      return;
   string bg = "EMAP_P_BG";
   if(ObjectFind(0,bg) < 0)
      ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bg,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,InpPanelX);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,InpPanelY);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,InpPanelWidth);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,(InpPanelRows + 5) * EmapRowH() + 12);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'18,20,26');
   ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,bg,OBJPROP_COLOR,C'55,60,75');
   ObjectSetInteger(0,bg,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,bg,OBJPROP_BACK,false);
   ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);
  }

void EmapScrollbarRender(const int eff,const int rowh)
  {
   string trk = "EMAP_P_SB_TRK";
   string thm = "EMAP_P_SB_THM";
   int    maxScroll = MathMax(0,g_listTotal - InpPanelRows);

   if(maxScroll <= 0)                       // nothing to scroll -> no scrollbar
     {
      ObjectDelete(0,trk);
      ObjectDelete(0,thm);
      g_sbMax = 0;
      return;
     }
   g_sbMax = maxScroll;

   // vertical track on the right edge of the panel, spanning the list rows
   g_sbTrackX = InpPanelX + g_panelW - 12;
   g_sbTrackY = InpPanelY + 5 + rowh;
   g_sbTrackH = InpPanelRows * rowh;

   if(ObjectFind(0,trk) < 0)
      ObjectCreate(0,trk,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,trk,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,trk,OBJPROP_XDISTANCE,g_sbTrackX);
   ObjectSetInteger(0,trk,OBJPROP_YDISTANCE,g_sbTrackY);
   ObjectSetInteger(0,trk,OBJPROP_XSIZE,7);
   ObjectSetInteger(0,trk,OBJPROP_YSIZE,g_sbTrackH);
   ObjectSetInteger(0,trk,OBJPROP_BGCOLOR,C'38,42,55');
   ObjectSetInteger(0,trk,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,trk,OBJPROP_COLOR,C'55,60,75');
   ObjectSetInteger(0,trk,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,trk,OBJPROP_BACK,false);
   ObjectSetInteger(0,trk,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,trk,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,trk,OBJPROP_ZORDER,5);

   // thumb sized by the fraction of the list currently visible
   int cell = (g_listTotal > 0) ? (g_sbTrackH / g_listTotal) : 0;
   int th   = MathMax(14,cell * InpPanelRows);
   if(th > g_sbTrackH)
      th = g_sbTrackH;
   g_sbThumbH = th;

   int ty = g_sbTrackY;
   if(g_sbTrackH > th && maxScroll > 0)
      ty += (g_sbTrackH - th) * eff / maxScroll;

   if(ObjectFind(0,thm) < 0)
      ObjectCreate(0,thm,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,thm,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,thm,OBJPROP_XDISTANCE,g_sbTrackX + 1);
   ObjectSetInteger(0,thm,OBJPROP_YDISTANCE,ty);
   ObjectSetInteger(0,thm,OBJPROP_XSIZE,5);
   ObjectSetInteger(0,thm,OBJPROP_YSIZE,th);
   ObjectSetInteger(0,thm,OBJPROP_BGCOLOR,g_sbDrag ? C'170,190,240' : C'120,140,190');
   ObjectSetInteger(0,thm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,thm,OBJPROP_COLOR,g_sbDrag ? C'170,190,240' : C'120,140,190');
   ObjectSetInteger(0,thm,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,thm,OBJPROP_BACK,false);
   ObjectSetInteger(0,thm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,thm,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,thm,OBJPROP_ZORDER,6);
  }

// cursor inside (or next to) the scrollbar track?
bool EmapSbHit(const int mx,const int my)
  {
   if(!InpShowPanel || g_sbMax <= 0)
      return false;
   return (mx >= g_sbTrackX - 6 && mx <= g_sbTrackX + 13 &&
           my >= g_sbTrackY - 4 && my <= g_sbTrackY + g_sbTrackH + 4);
  }

// scroll base matching a cursor y - thumb centre follows the cursor
int EmapSbEffFromY(const int my)
  {
   if(g_sbMax <= 0)
      return g_scroll;
   if(g_sbTrackH <= g_sbThumbH)
      return g_scroll;
   int t   = my - g_sbTrackY - g_sbThumbH / 2;
   int eff = t * g_sbMax / (g_sbTrackH - g_sbThumbH);
   return MathMax(0,MathMin(g_sbMax,eff));
  }

void EmapPanelUpdate()
  {
   if(!InpShowPanel)
      return;
   if(ObjectFind(0,"EMAP_P_BG") < 0)
      EmapPanelCreate();

   datetime now = TimeCurrent();

   // the panel obeys the same days-ahead filter as the chart lines
   datetime drawFrom,drawTo;
   EmapDrawWindow(drawFrom,drawTo);

   // ---- pass 1: catalogue the scrollable list - every group, past and upcoming
   int    total    = 0;
   int    follow   = -1;
   int    upcoming = 0;
   int    highNext = 0;
   int    titleW   = 0;                     // widest TITLE across the whole list
   for(int i = 0; i < g_nEv; )
     {
      int startb = i;
      int end    = EmapGroupEnd(startb);
      int best   = EmapBestInGroup(startb,end);
      int extra  = end - startb - 1;
      i          = end;

      if(g_ev[best].kind == EMAP_K_SESS && !InpShowSessions)
         continue;
      if(g_ev[best].imp < (int)InpMinImportance)
         continue;

      if(g_ev[best].t < drawFrom || g_ev[best].t > drawTo)
         continue;

      if(follow < 0 && g_ev[best].t >= now)
         follow = total;
      if(g_ev[best].t >= now)
        {
         upcoming++;
         if(g_ev[best].imp >= 3)
            highNext++;
        }
      total++;

      // measure the title column only: the width then only changes when the
      // feed changes, never while scrolling
      string ttl = g_ev[best].title;
      if(extra > 0)
         ttl += StringFormat(" +%d",extra);
      titleW = MathMax(titleW,EmapTextW(ttl));
     }
   g_listTotal  = total;
   g_listFollow = follow;

   int eff = (g_scroll < 0) ? ((follow < 0) ? 0 : follow) : g_scroll;
   eff     = MathMax(0,MathMin(eff,MathMax(0,total - InpPanelRows)));
   if(g_scroll >= 0)
      g_scroll = eff;                    // keep the sticky scroll bounded

   string headText = StringFormat("EVENT MAP   %d upcoming   %d high",upcoming,highNext);
   EmapPanelRow(0,headText,clrWhite,true);

   // ---- pass 2: render the window starting at the scroll base
   int shown = 0;
   int seen  = 0;
   for(int i = 0; i < g_nEv; )
     {
      int startb = i;
      int end    = EmapGroupEnd(startb);
      int best   = EmapBestInGroup(startb,end);
      int extra  = end - startb - 1;
      i          = end;

      if(g_ev[best].kind == EMAP_K_SESS && !InpShowSessions)
         continue;
      if(g_ev[best].imp < (int)InpMinImportance)
         continue;

      if(g_ev[best].t < drawFrom || g_ev[best].t > drawTo)
         continue;

      if(seen < eff)
        {
         seen++;
         continue;
        }
      if(shown >= InpPanelRows)
         break;

      string ttl = g_ev[best].title;     // full text, never truncated
      if(extra > 0)
         ttl += StringFormat(" +%d",extra);

      EmapPanelEventRow(1 + shown,
                        StringFormat("%-17s ",EmapDateHM(g_ev[best].t)),
                        StringFormat("%-6s ",EmapTag(g_ev[best]) +
                      ((g_ev[best].src == "") ? "" : " " + g_ev[best].src)),
                        StringFormat("%-4s ",EmapTrunc(g_ev[best].cur,4)),
                        ttl,EmapColor(g_ev[best]));
      shown++;
      seen++;
     }
   for(int k = shown; k < InpPanelRows; k++)
      EmapPanelEventRow(1 + k,"","","","",clrSilver);

   // ---- scrollbar status row
   int    lo   = MathMin(eff,MathMax(0,total - 1)) + 1;
   int    hi   = eff + shown;
   string srow = StringFormat("rows %d-%d of %d",lo,MathMin(hi,total),total);
   EmapPanelRow(1 + InpPanelRows,srow,clrSilver,false);

   // ---- footer row, measured too
   string feed = "off";
   if(InpUseCsv)
     {
      if(!g_csvOk)
         feed = "n/a";
      else if(g_csvAgeMin < 0)
         feed = "?";
      else if(g_csvAgeMin < 60)
         feed = StringFormat("%dm",g_csvAgeMin);
      else
         feed = StringFormat("%dh",g_csvAgeMin / 60);

      if(g_csvOk && InpCsvWarnHours > 0 && g_csvAgeMin > InpCsvWarnHours * 60)
         feed += "!";
     }

   string ptxt = g_srcList;
   string footText = StringFormat("server %+d   calendar %s   feed %s",
                                  (int)(EmapServerOffset() / 60),
                                  g_calOk ? "ok" : "n/a",
                                  feed);
   EmapPanelRow(InpPanelRows + 3,footText,clrSilver,false);

   // the two provider names live in their own object label, one line
   EmapPanelRow(InpPanelRows + 4,ptxt,clrSilver,false);

   // ---- stable width from the column layout:
   //      date+time column 16 chars + gap, tag 6 chars + gap, currency 4
   //      chars + gap -> the title column starts 29 chars in; then the
   //      widest title + a slim margin before the scrollbar track
   string srowMax = StringFormat("rows %d-%d of %d",
                                 MathMax(1,total - InpPanelRows + 1),
                                 total,MathMax(total,1));
   string headMax = StringFormat("EVENT MAP   %d upcoming   %d high",total,MathMax(total,1));
   int    cw      = EmapCharW();
   int    otherW  = MathMax(EmapTextW(headMax),
                           MathMax(EmapTextW(srowMax),
                           MathMax(EmapTextW(footText),EmapTextW(ptxt))));
   int paneW = MathMax(InpPanelWidth,
                       MathMax(8 + 29 * cw + titleW,8 + otherW) + 20);
   g_panelW  = paneW;
   if(ObjectFind(0,"EMAP_P_BG") >= 0)
     {
      ObjectSetInteger(0,"EMAP_P_BG",OBJPROP_XSIZE,paneW);
      ObjectSetInteger(0,"EMAP_P_BG",OBJPROP_YSIZE,(InpPanelRows + 5) * EmapRowH() + 12);
     }
   EmapScrollbarRender(eff,EmapRowH());
  }

//==================================================================
//  ALERTS
//==================================================================
bool EmapWasAlerted(const string uid)
  {
   for(int i = 0; i < g_nAlerted; i++)
      if(g_alerted[i] == uid)
         return true;
   return false;
  }

void EmapMarkAlerted(const string uid)
  {
   if(g_nAlerted >= 512)
     {
      for(int i = 0; i < 256; i++)
         g_alerted[i] = g_alerted[i + 256];
      g_nAlerted = 256;
     }
   ArrayResize(g_alerted,g_nAlerted + 1);
   g_alerted[g_nAlerted++] = uid;
  }

void EmapCheckAlerts()
  {
   if(InpAlertMinutesBefore <= 0)
      return;
   if(!InpAlertPopup && !InpAlertSound && !InpAlertPush)
      return;

   datetime now = TimeCurrent();
   long     win = (long)InpAlertMinutesBefore * 60;

   for(int i = 0; i < g_nEv; )
     {
      int start = i;
      int end   = EmapGroupEnd(start);
      int best  = EmapBestInGroup(start,end);
      int extra = end - start - 1;
      i = end;

      if(g_ev[best].kind == EMAP_K_SESS)
         continue;
      if(g_ev[best].imp < 3)
         continue;
      long diff = (long)g_ev[best].t - (long)now;
      if(diff <= 0 || diff > win)
         continue;
      if(EmapWasAlerted(g_ev[best].uid))
         continue;

      EmapMarkAlerted(g_ev[best].uid);
      string msg = StringFormat("EventMap %s in %d min: %s",
                                EmapHM(g_ev[best].t),(int)(diff / 60),g_ev[best].title);
      if(extra > 0)
         msg += StringFormat(" (+%d same minute)",extra);
      if(InpAlertPopup) Alert(msg);
      if(InpAlertSound) PlaySound("alert.wav");
      if(InpAlertPush)  SendNotification(msg);
      Print(msg);
     }
  }

//==================================================================
//  EVENT HANDLERS
//==================================================================
int OnInit()
  {
   ArrayResize(g_ev,EMAP_MAX);
   g_nEv       = 0;
   g_refreshed = false;
   g_calOk     = false;
   g_csvOk     = false;
   g_csvRows   = 0;
   g_csvAgeMin = -1;
   g_scroll    = -1;
   g_panelW    = 0;
   g_sbDrag    = false;
   g_sbMax     = 0;

   IndicatorSetString(INDICATOR_SHORTNAME,"EventMap");

   // needed for the scrollbar drag (mouse tracking on this chart)
   ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,1);

   // NO drawing or data loading here. Changing inputs calls OnInit
   // while the properties dialog is closing on the UI thread;
   // building objects/fetching the calendar in that window can
   // deadlock the whole terminal (freeze on OK).
   // g_refreshed stays false, so the first OnCalculate call - on
   // the indicator's own thread - does the full refresh + draw.

   if(InpVerbose)
      PrintFormat("EventMap init: %d events, server offset %+d min, calendar %s",
                  g_nEv,(int)(EmapServerOffset() / 60),g_calOk ? "ok" : "n/a");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_sbDrag = false;
   ChartSetInteger(0,CHART_MOUSE_SCROLL,true);
   ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,0);
   ObjectsDeleteAll(0,"EMAP_");
   ChartRedraw(0);
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2)
      return 0;

   static datetime lastBar = 0;
   static uint     lastMs  = 0;

   bool   newBar = (lastBar != time[0]);
   uint   nowMs  = GetTickCount();
   bool   due    = (InpRefreshMinutes > 0 &&
                    (long)(nowMs - lastMs) > (long)InpRefreshMinutes * 60000);

   if(newBar || !g_refreshed || prev_calculated == 0 || due)
     {
      lastBar = time[0];
      lastMs  = nowMs;
      EmapRefresh();
      EmapDrawLines();
      EmapDrawLabels();
      EmapPanelUpdate();
      ChartRedraw(0);
     }

   EmapCheckAlerts();
   return rates_total;
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   // price scale moved: labels are anchored to price, lines are not
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      if(InpShowLabels)
         EmapDrawLabels();
      EmapInfoHide();
      ChartRedraw(0);
      return;
     }

   // a click on a bare chart spot also closes the popup
   if(id == CHARTEVENT_CLICK)
     {
      EmapInfoHide();
      ChartRedraw(0);
      return;
     }

   // scrollbar: click the track or drag the thumb
   if(id == CHARTEVENT_MOUSE_MOVE)
     {
      int  mx   = (int)lparam;
      int  my   = (int)dparam;
      // left mouse button = bit 1 of the flags mask (MOUSE_LEFT has no
      // built-in identifier here, the bit value is 1)
      bool left = ((StringToInteger(sparam) & 1) != 0);

      if(g_sbDrag)
        {
         if(!left)                     // button released -> drop the thumb
           {
            g_sbDrag = false;
            ChartSetInteger(0,CHART_MOUSE_SCROLL,true);
            EmapPanelUpdate();
            ChartRedraw(0);
           }
         else
           {
            int eff = EmapSbEffFromY(my);
            if(eff != g_scroll)
              {
               g_scroll = eff;
               EmapPanelUpdate();
               ChartRedraw(0);
              }
           }
         return;
        }

      if(left && EmapSbHit(mx,my))
        {
         g_sbDrag = true;
         ChartSetInteger(0,CHART_MOUSE_SCROLL,false);  // keep the chart still while dragging
         int eff = EmapSbEffFromY(my);
         if(eff != g_scroll)
           {
            g_scroll = eff;
            EmapPanelUpdate();
            ChartRedraw(0);
           }
        }
      return;
     }

   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   // event line clicked -> show the info popup at the cursor
   if(StringFind(sparam,EMAP_PFX_LINE) == 0)
     {
      EmapInfoShow(sparam,(int)lparam,(int)dparam);
      ChartRedraw(0);
      return;
     }

   // any other object clicked -> close the popup
   EmapInfoHide();
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
