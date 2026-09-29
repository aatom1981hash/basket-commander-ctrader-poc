import "./style.css";
import { createClientAdapter } from "@spotware-web-team/sdk-external-api";
import {
  closePosition, executionEvent, getAccountInformation, getDealList, getLightSymbolList,
  handleConfirmEvent, registerEvent, ServerInterfaces
} from "@spotware-web-team/sdk";
import { catchError, take, tap } from "rxjs/operators";
import { createLogger } from "@veksa/logger";

const app = document.querySelector("#app");
const state = {
  connected:false, account:null, symbols:new Map(), positions:new Map(),
  error:"", busy:false, snapshotLoaded:false
};
let adapter = null;
let accountTimer = null;

const fmtMoney=(v,d=2)=>{
  if(v===undefined||v===null||Number.isNaN(Number(v))) return "—";
  return new Intl.NumberFormat("en-US",{style:"currency",currency:"USD",maximumFractionDigits:2}).format(Number(v)/(10**d));
};
const sideName=v=>v===ServerInterfaces.ProtoTradeSide.BUY?"BUY":"SELL";
const posOpen=p=>p?.positionStatus===ServerInterfaces.ProtoPositionStatus.POSITION_STATUS_OPEN ||
  p?.positionStatus===ServerInterfaces.ProtoPositionStatus.POSITION_STATUS_CREATED;
const symbolName=id=>state.symbols.get(id)?.name || `#${id}`;
const lots=p=>{
  const td=p?.tradeData||{}; const lot=td.lotSize||state.symbols.get(td.symbolId)?.lotSize;
  return lot?td.volume/lot:td.volume||0;
};

function baskets(){
  const map=new Map();
  for(const p of state.positions.values()){
    if(!posOpen(p)) continue;
    const td=p.tradeData||{}; const key=`${td.symbolId}:${td.tradeSide}`;
    if(!map.has(key)) map.set(key,{key,symbolId:td.symbolId,side:td.tradeSide,positions:[],lots:0});
    const b=map.get(key); b.positions.push(p); b.lots+=lots(p);
  }
  return [...map.values()].sort((a,b)=>symbolName(a.symbolId).localeCompare(symbolName(b.symbolId)));
}

function render(){
  const t=state.account?.trader||{};
  const md=t.moneyDigits ?? 2;
  app.innerHTML=`<div class="shell">
    <div class="topbar"><div class="brand">Basket Commander</div>
    <div class="status">${state.connected?"CONNECTED":"CONNECTING"}</div></div>
    ${state.error?`<div class="error">${state.error}</div>`:""}
    <section class="card metrics">
      <div class="metric"><div class="label">Balance</div><div class="value">${fmtMoney(t.balance,md)}</div></div>
      <div class="metric"><div class="label">Equity</div><div class="value">${fmtMoney(t.equity,md)}</div></div>
      <div class="metric"><div class="label">Margin</div><div class="value">${fmtMoney(t.usedMargin,md)}</div></div>
    </section>
    <div class="section-title">OPEN BASKETS</div>
    <div id="basket-list"></div>
    <div class="note">POC: positions are grouped by symbol + direction. No external login, VPS or Basket Commander server is used.</div>
  </div>`;
  const list=document.querySelector("#basket-list");
  const bs=baskets();
  if(!bs.length){
    const message=!state.connected?"Connecting to cTrader…":
      state.snapshotLoaded?"No open positions.":"Loading open positions…";
    list.innerHTML=`<section class="card empty">${message}</section>`;return;
  }
  for(const b of bs){
    const el=document.createElement("section"); el.className="card basket";
    el.innerHTML=`<div class="basket-head"><div><div class="basket-name">${symbolName(b.symbolId)}</div>
      <div class="subtle">${b.positions.length} position${b.positions.length===1?"":"s"}</div></div>
      <div class="badge">${sideName(b.side)}</div></div>
      <div class="basket-grid">
        <div class="smallbox"><div class="label">Positions</div><div class="value">${b.positions.length}</div></div>
        <div class="smallbox"><div class="label">Lots</div><div class="value">${b.lots.toFixed(2)}</div></div>
        <div class="smallbox"><div class="label">Basket P/L</div><div class="value">Live next</div></div>
      </div>
      <div class="actions"><button class="btn btn-danger btn-wide" data-close="${b.key}" ${state.busy?"disabled":""}>CLOSE BASKET</button></div>`;
    list.appendChild(el);
  }
  document.querySelectorAll("[data-close]").forEach(x=>x.addEventListener("click",()=>askClose(x.dataset.close)));
}

function askClose(key){
  const b=baskets().find(x=>x.key===key); if(!b)return;
  const modal=document.createElement("div"); modal.className="confirm";
  modal.innerHTML=`<div class="confirm-card"><div class="confirm-title">Close ${symbolName(b.symbolId)} ${sideName(b.side)} basket?</div>
    <div class="subtle">${b.positions.length} positions · ${b.lots.toFixed(2)} lots</div>
    <div class="note" style="margin-top:12px">Market execution can differ because of price movement, liquidity and slippage.</div>
    <div class="confirm-actions"><button class="btn" id="cancel-close">CANCEL</button><button class="btn btn-danger" id="confirm-close">CLOSE BASKET</button></div></div>`;
  document.body.appendChild(modal);
  modal.querySelector("#cancel-close").onclick=()=>modal.remove();
  modal.querySelector("#confirm-close").onclick=()=>{modal.remove();closeBasket(b);};
}

function closeBasket(b){
  state.busy=true; state.error=""; render();
  let remaining=b.positions.length;
  for(const p of b.positions){
    const td=p.tradeData||{};
    closePosition(adapter,{positionId:p.positionId,volume:td.volume})
      .pipe(take(1),catchError(err=>{state.error=`Close failed: ${err?.message||err}`;return [];}))
      .subscribe({complete:()=>{remaining--;if(remaining<=0){state.busy=false;render();}}});
  }
}

function loadAccount(){
  if(!state.connected)return;
  getAccountInformation(adapter,{}).pipe(take(1),tap(res=>{state.account=res;render();}),
    catchError(err=>{state.error=`Account read failed: ${err?.message||err}`;render();return [];})).subscribe();
}

function loadSymbols(){
  getLightSymbolList(adapter,{}).pipe(take(1),tap(res=>{
    for(const s of (res.symbol||[])) state.symbols.set(s.symbolId,s);
    render();
  }),catchError(()=>[])).subscribe();
}

// The WebView SDK exposes execution events but no direct "open positions" snapshot.
// For hedging accounts, rebuild currently open positions from recent filled deals.
function loadPositionSnapshot(){
  const now=Date.now();
  const from=now-(180*24*60*60*1000);
  getDealList(adapter,{fromTimestamp:from,toTimestamp:now}).pipe(
    take(1),
    tap(res=>{
      const byPosition=new Map();
      for(const d of (res.deal||[])){
        if(!d?.positionId || !d?.filledVolume) continue;
        if(d.dealStatus!==ServerInterfaces.ProtoDealStatus.FILLED &&
           d.dealStatus!==ServerInterfaces.ProtoDealStatus.PARTIALLY_FILLED) continue;
        const signed=d.tradeSide===ServerInterfaces.ProtoTradeSide.BUY?d.filledVolume:-d.filledVolume;
        const cur=byPosition.get(d.positionId)||{
          positionId:d.positionId,symbolId:d.symbolId,netVolume:0,
          openTimestamp:d.executionTimestamp||d.createTimestamp||now,
          lotSize:d.lotSize
        };
        cur.netVolume+=signed;
        cur.symbolId=d.symbolId||cur.symbolId;
        cur.openTimestamp=Math.min(cur.openTimestamp,d.executionTimestamp||d.createTimestamp||cur.openTimestamp);
        cur.lotSize=d.lotSize||cur.lotSize;
        byPosition.set(d.positionId,cur);
      }

      state.positions.clear();
      for(const p of byPosition.values()){
        if(Math.abs(p.netVolume)<1) continue;
        state.positions.set(p.positionId,{
          positionId:p.positionId,
          positionStatus:ServerInterfaces.ProtoPositionStatus.POSITION_STATUS_OPEN,
          tradeData:{
            symbolId:p.symbolId,
            volume:Math.abs(p.netVolume),
            tradeSide:p.netVolume>0?ServerInterfaces.ProtoTradeSide.BUY:ServerInterfaces.ProtoTradeSide.SELL,
            openTimestamp:p.openTimestamp,
            lotSize:p.lotSize
          }
        });
      }
      state.snapshotLoaded=true;
      if(res.hasMore) state.error="Position snapshot is partial: deal history returned more records than one response.";
      render();
    }),
    catchError(err=>{
      state.snapshotLoaded=true;
      state.error=`Position snapshot failed: ${err?.message||err}`;
      render();
      return [];
    })
  ).subscribe();
}

function onExecution(ev){
  const p=ev?.position; if(!p)return;
  if(posOpen(p)) state.positions.set(p.positionId,p); else state.positions.delete(p.positionId);
  render();
}

function connect(){
  const logger=createLogger(location.search.includes("showLogs"));
  adapter=createClientAdapter({logger});
  handleConfirmEvent(adapter,{}).pipe(take(1)).subscribe();
  registerEvent(adapter).pipe(take(1),tap(()=>{
    handleConfirmEvent(adapter,{}).pipe(take(1)).subscribe();
    state.connected=true; state.error="";
    executionEvent(adapter).pipe(tap(onExecution)).subscribe();
    loadSymbols(); loadAccount(); loadPositionSnapshot();
    accountTimer=setInterval(loadAccount,2000);
    render();
  }),catchError(err=>{state.error=`cTrader host connection failed: ${err?.message||err}`;render();return [];})).subscribe();
}

window.addEventListener("beforeunload",()=>{if(accountTimer)clearInterval(accountTimer);});
render();
connect();
