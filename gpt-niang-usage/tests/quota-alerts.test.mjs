import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeQuotaAlertSettings,reduceQuotaAlerts,shouldPollQuota} from '../runtime/quota-alerts.mjs';

const start=2000000000000;
const enabled={version:1,enabled:true};
const window=(remaining,minutes=300,resetsAt=null)=>({minutes,remaining,resetsAt,label:minutes+' min'});
function snapshot(remaining,at=start,extra={}){return {ok:true,queryOk:true,observedAt:at,accountKey:'account-a',plan:'pro',planLabel:'Pro',windows:[window(remaining)],...extra};}
function step(state,value,offset=0,options={}){const now=start+offset;return reduceQuotaAlerts(state,snapshot(value,now,options),enabled,{now});}

test('settings reject malformed opt-ins and threshold ordering',()=>{
  assert.equal(normalizeQuotaAlertSettings({enabled:true}).enabled,false);
  assert.deepEqual(normalizeQuotaAlertSettings(null),{version:1,enabled:false,recovery:true,background:false,low:25,critical:10,hysteresis:2,revision:null});
  assert.equal(normalizeQuotaAlertSettings({low:2,critical:9}).critical,1);
});

test('startup warns most severe once and persisted observations do not replay',()=>{
  let state=step(null,5);
  assert.deepEqual(state.events.map(event=>event.type),['critical']);
  const id=state.events[0].id;
  state=reduceQuotaAlerts(JSON.parse(JSON.stringify(state)),snapshot(5),enabled,{now:start,ackIds:[id]});
  assert.equal(state.events.length,0);
  state=step(state,4,1000);
  assert.equal(state.events.length,0);
  state=step(state,0,2000);
  assert.deepEqual(state.events.map(event=>event.type),['exhausted']);
});

test('hysteresis rearms a genuinely new downward episode',()=>{
  let state=step(null,24);
  const first=state.events[0].id;
  state=reduceQuotaAlerts(state,null,enabled,{now:start,ackIds:[first]});
  state=step(state,26,1000);state=step(state,24,2000);
  assert.equal(state.events.length,0);
  state=step(state,28,3000);state=step(state,24,4000);
  assert.equal(state.events.length,1);assert.notEqual(state.events[0].id,first);
});

test('missing reset needs two advancing positive observations and cancels warnings',()=>{
  let state=step(null,0);
  state=step(state,50,1000);assert.equal(state.events.length,0);assert.equal(state.windows['minutes:300'].depleted,true);
  state=step(state,50,1000);assert.equal(state.events.length,0);assert.equal(state.windows['minutes:300'].positiveCount,1);
  state=step(state,50,2000);assert.deepEqual(state.events.map(event=>event.type),['recovered']);
});

test('known reset cannot recover early even if a sample advertises a later boundary',()=>{
  const boundary=(start+10000)/1000;
  let state=step(null,0,0,{windows:[window(0,300,boundary)]});
  state=step(state,90,1000,{windows:[window(90,300,boundary+300)]});
  state=step(state,90,2000,{windows:[window(90,300,boundary+300)]});
  assert.equal(state.events.length,0);assert.equal(state.windows['minutes:300'].depleted,true);
  state=step(state,90,11000,{windows:[window(90,300,boundary+300)]});
  assert.equal(state.events[0].type,'recovered');
});

test('new future metadata does not block a previously boundaryless recovery confirmation',()=>{
  let state=step(null,0);
  state=step(state,80,1000,{windows:[window(80,300,(start+600000)/1000)]});
  state=step(state,80,2000,{windows:[window(80,300,(start+600000)/1000)]});
  assert.equal(state.events[0].type,'recovered');
});

test('failed stale future and out of order samples never restore',()=>{
  let state=step(null,0);
  for(const sample of [snapshot(90,start+1,{queryOk:false}),snapshot(90,start-1),snapshot(90,start+2000)]){
    state=reduceQuotaAlerts(state,sample,enabled,{now:start+1000});
    assert.equal(state.events[0].type,'exhausted');
  }
  state=reduceQuotaAlerts(state,snapshot(90,start+1),enabled,{now:start+200000});
  assert.equal(state.events[0].type,'exhausted');
});

test('account plan and unknown identity changes do not fabricate recovery',()=>{
  let state=step(null,0);
  state=step(state,90,1000,{accountKey:'account-b'});assert.equal(state.events.length,0);
  state=step(state,0,2000);state=step(state,90,3000,{plan:'plus',planLabel:'Plus'});assert.equal(state.events.length,0);
  state=step(state,0,4000);state=step(state,90,5000,{accountKey:null});
  assert.equal(state.events.length,0);assert.equal(state.accountKey,null);
});

test('pending warnings disappear when a later sample is above their original threshold and hysteresis',()=>{
  let state=step(null,20);
  state=step(state,90,1000);assert.equal(state.events.length,0);
  state=step(null,5);
  state=step(state,11,1000);assert.equal(state.events[0].type,'critical');
  state=step(state,13,2000);assert.equal(state.events.length,0);
});

test('expired windows cancel pending events without announcing recovery',()=>{
  const reset=(start+1000)/1000;
  let state=step(null,20,0,{windows:[window(20,300,reset)]});
  state=step(state,90,2000,{windows:[window(90,300,reset)]});
  assert.equal(state.events.length,0);
});

test('revision changes survive heartbeat and baseline a fast disable-enable roundtrip',()=>{
  let state=reduceQuotaAlerts(null,snapshot(20),{...enabled,revision:'first'},{now:start});
  state=reduceQuotaAlerts(state,null,{...enabled,revision:'second'},{now:start+1000});
  assert.equal(state.events.length,0);assert.equal(state.baselinePending,true);
  assert.equal(state.settingsRevision,'second');
  state=reduceQuotaAlerts(state,snapshot(20,start+2000),{...enabled,revision:'second'},{now:start+2000});
  assert.equal(state.events.length,0);assert.equal(state.baselinePending,false);
  state=reduceQuotaAlerts(null,snapshot(0),{...enabled,revision:'first'},{now:start});
  state=reduceQuotaAlerts(state,snapshot(90,start+1000),{...enabled,revision:'second'},{now:start+1000});
  assert.equal(state.events.length,0);assert.equal(state.windows['minutes:300'].depleted,false);
});

test('unknown plans keep low warnings but cannot announce recovery',()=>{
  let state=step(null,20,0,{plan:null,planLabel:'未知套餐'});
  assert.equal(state.plan,null);assert.equal(state.events[0].type,'low');
  state=step(state,0,1000,{plan:null,planLabel:'未知套餐'});
  state=step(state,90,2000,{plan:null,planLabel:'未知套餐'});
  state=step(state,90,3000,{plan:null,planLabel:'未知套餐'});
  assert.equal(state.events.length,0);
});

test('settings bounds match the PS thresholds and revision contract',()=>{
  const normalized=normalizeQuotaAlertSettings({...enabled,low:100,critical:0,hysteresis:11,revision:'changed'});
  assert.equal(normalized.low,25);assert.equal(normalized.critical,10);assert.equal(normalized.hysteresis,2);
  assert.equal(normalized.revision,'changed');
  const small=normalizeQuotaAlertSettings({...enabled,low:1,critical:0});
  assert.ok(small.critical>0 && small.critical<small.low);
});

test('independent windows preserve separate pending events, ttl and cap are bounded',()=>{
  let state=step(null,0,0,{windows:[window(20),window(5,10080)]});
  assert.deepEqual(state.events.map(event=>event.type),['low','critical']);
  state=reduceQuotaAlerts(state,null,enabled,{now:start+600000});assert.equal(state.events.length,0);
  state=step(null,0,0,{windows:Array.from({length:40},(_,index)=>window(0,index+1))});
  assert.equal(state.events.length,32);
});

test('disabled clears pending and enabling through heartbeat baselines old quota',()=>{
  let state=step(null,0);
  state=reduceQuotaAlerts(state,null,{version:1,enabled:false},{now:start+1000});assert.equal(state.events.length,0);
  state=reduceQuotaAlerts(state,null,enabled,{now:start+2000});
  state=step(state,0,3000);assert.equal(state.events.length,0);
  state=step(state,50,4000);state=step(state,50,5000);
  assert.equal(state.events[0].type,'recovered');
});

test('background gate is Windows only and requires live fresh GUI presence',()=>{
  const settings={...enabled,background:true};
  const input={platform:'win32',settings,now:start,presence:{visible:false,pid:12,at:start},isAlive:pid=>pid===12};
  assert.equal(shouldPollQuota(input),true);
  assert.equal(shouldPollQuota({...input,platform:'darwin'}),false);
  assert.equal(shouldPollQuota({...input,isAlive:()=>false}),false);
  assert.equal(shouldPollQuota({...input,now:start+5000}),false);
  assert.equal(shouldPollQuota({...input,settings:{...settings,enabled:false}}),false);
  assert.equal(shouldPollQuota({...input,platform:'darwin',presence:{...input.presence,visible:true}}),true);
});
