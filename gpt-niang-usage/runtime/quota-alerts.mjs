import {createHash} from 'node:crypto';

const TTL=600000;
const finite=value=>typeof value==='number' && Number.isFinite(value);

/** Normalize the PS-owned settings; missing or malformed opt-ins stay disabled. */
export function normalizeQuotaAlertSettings(raw) {
  const low=finite(raw?.low) && raw.low>=1 && raw.low<=99?raw.low:25;
  const critical=finite(raw?.critical) && raw.critical>0 && raw.critical<low?raw.critical:Math.min(10,low/2);
  return {version:1,enabled:raw?.version===1 && raw.enabled===true,recovery:raw?.recovery!==false,
    background:raw?.background===true,low,critical,
    hysteresis:finite(raw?.hysteresis) && raw.hysteresis>=0 && raw.hysteresis<=10?raw.hysteresis:2,
    revision:typeof raw?.revision==='string' && raw.revision.length<=64?raw.revision:null};
}

/** Preserve visible polling on both platforms; hidden polling requires a live Windows GUI opt-in. */
export function shouldPollQuota({platform=process.platform,presence,now=Date.now(),settings,isAlive=()=>false}) {
  const live=presence && finite(presence.at) && now-presence.at>=0 && now-presence.at<5000 && isAlive(presence.pid);
  const options=normalizeQuotaAlertSettings(settings);
  return Boolean(live && (presence.visible || (platform==='win32' && options.enabled && options.background)));
}

function eventID(parts){return createHash('sha256').update(JSON.stringify(parts)).digest('hex').slice(0,32);}
function windowKey(window){return window.kind==='individual'?'individual':Number.isSafeInteger(window.minutes) && window.minutes>0?'minutes:'+window.minutes:null;}

/**
 * Pure persisted reducer. Times are milliseconds except upstream resetsAt (seconds).
 * A null snapshot only applies settings, acknowledgements and expiry; cached failed queries never recover quota.
 */
export function reduceQuotaAlerts(previous,snapshot,rawSettings,{now=Date.now(),ackIds=[]}={}) {
  const settings=normalizeQuotaAlertSettings(rawSettings);
  const prior=previous?.version===1?previous:null;
  const state={version:1,accountKey:prior?.accountKey??null,plan:prior?.plan??null,
    enabled:settings.enabled,initialized:prior?.initialized===true,observedAt:prior?.observedAt??null,settingsRevision:settings.revision,
    baselinePending:prior?.baselinePending===true || (prior?.initialized===true && (prior.enabled===false || (prior.settingsRevision??null)!==settings.revision)),windows:{...(prior?.windows??{})},events:[]};
  const acknowledged=new Set(Array.isArray(ackIds)?ackIds.filter(id=>typeof id==='string'):[]);
  state.events=(Array.isArray(prior?.events)?prior.events:[]).filter(event=>event && typeof event.id==='string' &&
    event.accountKey===state.accountKey && finite(event.at) && now-event.at>=0 && now-event.at<TTL && !acknowledged.has(event.id)).slice(-32);
  if(!settings.enabled){state.events=[];state.windows={};return state;}
  const reenabling=state.baselinePending;
  if(reenabling){state.events=[];state.windows={};}
  if(!snapshot)return state;
  const account=typeof snapshot.accountKey==='string' && snapshot.accountKey? snapshot.accountKey:null;
  if(!account){state.accountKey=null;state.plan=null;state.windows={};state.events=[];return state;}
  const plan=snapshot.planType??snapshot.plan??null;
  const identityChanged=account!==state.accountKey || plan!==state.plan;
  if(identityChanged){state.accountKey=account;state.plan=plan;state.observedAt=null;state.windows={};state.events=[];}
  if(!snapshot.ok || !snapshot.queryOk || !finite(snapshot.observedAt) || snapshot.observedAt>now || now-snapshot.observedAt>180000 || !Array.isArray(snapshot.windows))return state;
  const at=snapshot.observedAt;
  if(state.observedAt!==null && at<=state.observedAt)return state;
  const seen=new Set();
  for(const window of snapshot.windows){
    const key=windowKey(window);
    if(!key || seen.has(key) || !finite(window.remaining) || window.remaining<0 || window.remaining>100)continue;
    seen.add(key);
    const reset=finite(window.resetsAt) && window.resetsAt>0?window.resetsAt*1000:null;
    const old=state.windows[key];
    if(old && at<=old.at)continue;
    // Reaching a countdown boundary alone is never evidence that fresh quota exists.
    if(reset!==null && reset<=now){state.events=state.events.filter(event=>event.windowKey!==key);continue;}
    const remaining=window.remaining;
    let current=old?{...old,fired:[...(old.fired??[])]}:{at,remaining,reset,episode:at,fired:[],depleted:false,positiveCount:0};
    const advanced=old?.reset!=null && reset!=null && reset>old.reset+60000 && now>=old.reset && at>=old.reset;
    if(advanced){current.fired=[];current.episode=at;}
    current.fired=current.fired.filter(threshold=>remaining<=threshold+settings.hysteresis);
    if(old && current.fired.length<(old.fired??[]).length)current.episode=at;
    state.events=state.events.filter(event=>{
      if(event.windowKey!==key || event.type==='recovered')return true;
      const threshold=event.threshold??(event.type==='exhausted'?0:event.type==='critical'?settings.critical:settings.low);
      return remaining<=threshold+settings.hysteresis;
    });
    let type=null;
    if(old?.depleted && remaining>0){
      const boundaryReady=old.reset==null || (now>=old.reset && at>=old.reset);
      current.positiveCount=boundaryReady?(old.positiveCount??0)+1:0;
      if(boundaryReady && (advanced || current.positiveCount>=2)){
        current.depleted=false;current.fired=[];current.episode=at;current.positiveCount=0;
        state.events=state.events.filter(event=>event.windowKey!==key);
        if(settings.recovery && typeof plan==='string' && plan && plan!=='未知套餐')type='recovered';
      }
    }else if(remaining===0){current.depleted=true;current.positiveCount=0;}
    const thresholds=[0,settings.critical,settings.low].filter((value,index,list)=>list.indexOf(value)===index);
    const crossed=thresholds.find(threshold=>remaining<=threshold && !current.fired.includes(threshold));
    if(crossed!==undefined && !reenabling){
      if(type!=='recovered')type=crossed===0?'exhausted':crossed===settings.critical?'critical':'low';
      current.fired=[...new Set([...current.fired,...thresholds.filter(threshold=>threshold>=crossed)])];
    }
    if(reenabling)current.fired=thresholds.filter(threshold=>remaining<=threshold);
    if(type){
      const event={id:eventID([account,plan,key,current.episode,type,type==='low'?settings.low:type==='critical'?settings.critical:0]),
        type,windowKey:key,label:typeof window.label==='string'?window.label.slice(0,80):key,remaining,at,accountKey:account,
        threshold:type==='low'?settings.low:type==='critical'?settings.critical:0};
      // A newer, more severe event replaces that window's obsolete warning, not other windows.
      state.events=state.events.filter(item=>item.windowKey!==key);
      if(!acknowledged.has(event.id))state.events.push(event);
    }
    current.at=at;current.remaining=remaining;
    current.reset=current.depleted && old && !advanced?old.reset:reset;
    state.windows[key]=current;
  }
  for(const key of Object.keys(state.windows))if(!seen.has(key)){delete state.windows[key];state.events=state.events.filter(event=>event.windowKey!==key);}
  state.initialized=true;
  state.observedAt=at;
  state.baselinePending=false;
  state.events=state.events.slice(-32);
  return state;
}
