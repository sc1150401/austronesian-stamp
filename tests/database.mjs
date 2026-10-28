import {PGlite} from '@electric-sql/pglite';
import fs from 'node:fs';import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec(`create role anon; create role authenticated; create role service_role bypassrls; create schema auth; create table auth.users(id uuid primary key);`);
await db.exec(fs.readFileSync('tests/base.sql','utf8'));
await db.exec(`alter table stamp_redemptions add column redemption_no smallint not null default 1 check(redemption_no between 1 and 2);alter table stamp_redemptions drop constraint stamp_redemptions_participant_id_key;create unique index on stamp_redemptions(participant_id,redemption_no);`);
const migration=fs.readFileSync('supabase/migrations/202610280003_admin.sql','utf8');
await db.exec(migration);await db.exec(migration);
const actor='11111111-1111-4111-8111-111111111111',outsider='22222222-2222-4222-8222-222222222222';
await db.query('insert into auth.users values($1),($2)',[actor,outsider]);await db.query('insert into stamp_admins(user_id) values($1)',[actor]);
const rpc=async(action,payload={},user=actor)=>(await db.query('select stamp_admin_api($1,$2,$3) result',[user,action,JSON.stringify(payload)])).rows[0].result;
await assert.rejects(()=>rpc('overview',{},outsider),/ADMIN_REQUIRED/);
for(let n=0;n<=6;n++){
 const p=(await db.query('insert into stamp_participants(line_user_id,created_at) values($1,$2) returning id',[`user${n}`,'2026-10-27T17:00:00Z'])).rows[0];
 for(let i=1;i<=n;i++)await db.query('insert into stamp_records values($1,$2,$3)',[p.id,i,'2026-10-27T17:10:00Z']);
 if(n>=3)await db.query("insert into stamp_redemptions(participant_id,vendor_id,redeemed_by,redemption_no,redeemed_at) values($1,1,'self',1,$2)",[p.id,'2026-10-27T17:30:00Z']);
 if(n===6)await db.query("insert into stamp_redemptions(participant_id,vendor_id,redeemed_by,redemption_no,redeemed_at) values($1,1,'self',2,$2)",[p.id,'2026-10-27T17:31:00Z']);
}
const stats=await rpc('overview');assert.equal(stats.total,7);assert.equal(stats.started,6);assert.equal(stats.completed,1);assert.equal(stats.redeemed_total,5);assert.deepEqual(stats.stamp_distribution.map(x=>x.people),[1,1,1,1,1,1,1]);assert.deepEqual(stats.redemption_distribution.map(x=>x.people),[3,3,1]);assert.equal(stats.vendors[0].people,4);assert.equal(stats.vendors[0].portions,5);assert.equal(stats.daily[0].day,'2026-10-28');
const before=await rpc('participant',{number:'7'});const reset={number:'7',revision:before.revision,mode:'all',reason:'測試重設',request_id:'33333333-3333-4333-8333-333333333333'};
await assert.rejects(()=>rpc('reset',{...reset,revision:'wrong'}),/RECORD_CHANGED/);
await rpc('reset',reset);const after=await rpc('participant',{number:'7'});assert.equal(after.number,'7');assert.equal(after.stamps.length,0);assert.equal(after.redemptions.length,0);
await db.exec(`insert into stamp_records(participant_id,station_id) select id,1 from stamp_participants where participant_no=7`);
assert.equal((await rpc('reset',reset)).already_applied,true);assert.equal((await rpc('participant',{number:'7'})).stamps.length,1);
assert.equal((await rpc('participant',{number:'6'})).stamps.length,5);
assert.equal((await rpc('audit')).rows[0].before_data.stamps.length,6);
await rpc('catalog',{kind:'station',id:1,name:'山林站',active:true,reason:'更名測試',expected:{id:1,name:'集章點 01',active:false},request_id:'44444444-4444-4444-8444-444444444444'});
assert.equal((await rpc('overview')).stations[0].name,'山林站');
assert.equal((await rpc('participants',{after:'3',limit:2})).rows.length,2);
await db.exec('set role anon');await assert.rejects(()=>rpc('overview'),/permission denied/);await assert.rejects(()=>db.query('select * from stamp_admin_audit'),/permission denied/);await db.exec('reset role');
// Stats and pagination must not stop at PostgREST's usual 1000-row limit.
await db.exec("insert into stamp_participants(line_user_id) select 'bulk'||n from generate_series(1,1100)n");assert.equal((await rpc('overview')).total,1107);
let all=[],cursor='0';for(;;){const page=(await rpc('participants',{after:cursor,limit:500})).rows;all.push(...page);if(page.length<500)break;cursor=page.at(-1).number;}assert.equal(all.length,1107);
console.log('PASS: idempotent migration; admin gate and denied anon; 0–6 exact buckets; same-vendor person/portion counts; Taiwan dates; reset isolation, audit, stale protection, retry safety; catalog; >1000 participants');
await db.close();
