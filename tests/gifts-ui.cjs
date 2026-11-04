const fs=require('fs'),assert=require('assert'),{JSDOM}=require('jsdom'),vm=require('vm');
(async()=>{
const dom=new JSDOM(fs.readFileSync('index.html','utf8'),{url:'https://sc1150401.github.io/austronesian-stamp/',runScripts:'outside-only'}),w=dom.window;
w.HTMLDialogElement.prototype.showModal=function(){this.open=true};w.HTMLDialogElement.prototype.close=function(){this.open=false};
w.eval(w.document.querySelectorAll('script')[1].textContent.replace(/initLine\(\);\s*$/,'')+';window.api={renderAccount,openReward,rewardRequest};');
const base={ok:true,rules_version:'gifts-v1',gift_ready:true,stamps:Array.from({length:6},(_,i)=>({station_id:i+1})),gifts:[{id:1,name:'南島紋身貼紙',stamp_cost:2,active:true},{id:2,name:'南島特色襪子',stamp_cost:4,active:true},{id:3,name:'南島絲巾禮盒',stamp_cost:6,active:true}],redemptions:[]};
const buttons=()=>[...w.document.querySelectorAll('#rewards button')].map(b=>b.disabled);
w.api.renderAccount({...base,stamps:base.stamps.slice(0,2)});assert.deepEqual(buttons(),[false,true,true]);
w.api.renderAccount(base);assert.deepEqual(buttons(),[false,false,false]);
w.api.renderAccount({...base,redemptions:[{id:'a',gift_id:1,stamp_cost:2,redeemed_at:new Date().toISOString()}]});assert.deepEqual(buttons(),[true,false,true]);assert(w.document.getElementById('receipt').textContent.includes('剩餘可用 4 章'));
w.api.openReward(2);assert(w.document.getElementById('redeem-question').textContent.includes('將扣除 4 章，剩餘 0 章'));assert(!w.document.getElementById('redeem-question').textContent.includes('試吃'));
w.api.renderAccount({...base,redemptions:[{id:'b',gift_id:3,stamp_cost:6,redeemed_at:new Date().toISOString()}]});assert.deepEqual(buttons(),[true,true,true]);
w.api.renderAccount({...base,rules_version:'pending',gift_ready:false});assert.deepEqual(buttons(),[true,true,true]);
w.AbortSignal=AbortSignal;w.liff={getIDToken:()=> 'test'};let paths=[];w.fetch=async(url)=>{paths.push(url);if(url.endsWith('stamp-gifts'))throw Error('not deployed');return{ok:true,json:async()=>({...base,redemptions:[],vendors:[]})}};
const pending=await w.api.rewardRequest('status');assert.equal(pending.gift_ready,false);assert.equal(pending.redemptions.length,0);paths=[];await assert.rejects(()=>w.api.rewardRequest('redeem',{gift_id:1}));assert.equal(paths.length,1);assert(paths[0].endsWith('stamp-gifts'));
let handler,dbCalls=0;const src=fs.readFileSync('supabase/functions/stamp-gifts/index.js','utf8');const context={Deno:{serve:fn=>handler=fn,env:{get:()=> 'test'}},Response,Request,URLSearchParams,AbortSignal,Date,fetch:async url=>{if(String(url).includes('api.line.me'))return new Response('{}',{status:401});dbCalls++;throw Error('unexpected DB access')}};vm.runInNewContext(src,context);
const res=await handler(new Request('https://example.test',{method:'POST',body:JSON.stringify({action:'redeem',gift_id:1,id_token:'invalid'})}));assert.equal(res.status,401);assert.equal(dbCalls,0);
console.log('PASS gifts UI: thresholds; spent budget; unique gifts; warning; disabled deployment; no legacy redemption fallback; rejected identity never reaches DB');
})();
