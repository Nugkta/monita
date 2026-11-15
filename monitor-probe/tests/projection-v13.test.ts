import test from 'node:test';
import assert from 'node:assert/strict';
import { latestTurn, patchProjection, projectConversation, sessionFromProjection,
  validateConversation } from '../source/src/providers/codex/projection';
import type { Session } from '../source/src/shared/types';

const base: Session = { id:'codex:fixture-thread', provider:'codex', externalId:'fixture-thread',
  title:'Synthetic', directory:null, status:'unknown', detail:'', updatedAt:1, observedAt:1,
  evidence:'unavailable', attentionKey:null, archived:false };
function snapshot() {
  return { id:'fixture-thread', threadRuntimeStatus:{type:'idle',activeFlags:[]}, hasUnreadTurn:true,
    requests:[], turns:[{turnId:'legacy-stale',status:'completed',turnStartedAtMs:999999}],
    turnHistory:{kind:'canonical',history:{
      entitiesByKey:{ old:{turnId:'old',status:'completed',turnStartedAtMs:99999},
        current:{turnId:'current',status:'completed',turnStartedAtMs:1},
        orphan:{turnId:'orphan',status:'completed',turnStartedAtMs:9999999} },
      islands:[{id:'island',entries:[{key:'entry-old',value:'old'},{key:'entry-current',value:'current'}],
        olderBoundary:{status:'available'},newerBoundary:{status:'exhausted'}}],isComplete:false } } };
}
const session = (s: unknown) => sessionFromProjection(base, projectConversation(s,13), 100);

test('v13 canonical latest is current-head ordering, independent of timestamps and orphan entities',()=>{
  const raw=snapshot(); validateConversation(raw,13);
  const projected=projectConversation(raw,13);
  assert.equal(latestTurn(projected)?.turnId,'current');
  assert.equal(sessionFromProjection(base,projected).attentionKey,'result:current');
});

test('a partial final island cannot borrow an older exhausted island or legacy turn',()=>{
  const raw=snapshot();
  raw.turnHistory.history.islands.push({id:'partial',entries:[{key:'entry-old',value:'old'}],
    olderBoundary:{status:'available'},newerBoundary:{status:'available'}});
  validateConversation(raw,13);
  assert.equal(latestTurn(projectConversation(raw,13)),undefined);
  assert.equal(session(raw).status,'review');
  assert.equal(session(raw).attentionKey,null);
});

test('missing newest entry or entity yields no identity and never scans backward',()=>{
  const raw=snapshot();
  delete (raw.turnHistory.history.entitiesByKey as any).current;
  assert.equal(session(raw).attentionKey,null);
  raw.turnHistory.history.islands[0].entries=[];
  assert.equal(session(raw).attentionKey,null);
});

test('missing real v13 turn ID cannot borrow an entity-key or legacy id',()=>{
  const raw=snapshot() as any;
  raw.turnHistory.history.entitiesByKey.current={id:'local-ui-id',status:'completed'};
  assert.equal(session(raw).attentionKey,null);
});

test('v13 incomplete or nonterminal head preserves unread state without asserting a result',()=>{
  for(const status of ['inProgress','unknown',undefined]) {
    const raw=snapshot() as any;
    raw.turnHistory.history.entitiesByKey.current.status=status;
    if(status===undefined) delete raw.turnHistory.history.entitiesByKey.current.status;
    const s=session(raw);
    assert.equal(s.status,'review');assert.equal(s.attentionKey,null);
  }
});

test('terminal failed and interrupted heads stay distinguishable while using verified identity',()=>{
  for(const status of ['failed','interrupted']) {
    const raw=snapshot();raw.turnHistory.history.entitiesByKey.current.status=status;
    const s=session(raw);assert.equal(s.attentionKey,'result:current');assert.match(s.detail,new RegExp(status));
  }
});

test('v13 noncanonical turns follow source order while v11 retains its timestamp fallback',()=>{
  const raw={id:'fixture-thread',threadRuntimeStatus:{type:'idle'},hasUnreadTurn:true,requests:[],
    turns:[{turnId:'first',status:'completed',turnStartedAtMs:100},{turnId:'last',status:'completed',turnStartedAtMs:1}]};
  assert.equal(latestTurn(projectConversation(raw,13))?.turnId,'last');
  assert.equal(latestTurn(projectConversation(raw,11))?.turnId,'first');
});

test('unknown history kind cannot establish a v13 completion',()=>{
  const raw=snapshot();raw.turnHistory.kind='future-kind';assert.equal(session(raw).attentionKey,null);
});

test('snapshot projection removes all raw body, tool, request arguments and runtime extras',()=>{
  const raw=snapshot() as any;
  raw.prompt='SECRET';raw.turns[0].items=[{text:'SECRET'}];
  raw.threadRuntimeStatus.toolPayload={prompt:'SECRET'};
  raw.requests=[{id:7,method:'requestApproval',arguments:{content:'SECRET'}}];
  raw.turnHistory.history.entitiesByKey.current.items=[{response:'SECRET'}];
  raw.turnHistory.history.islands[0].entries[0].message='SECRET';
  raw.turnHistory.history.islands[0].newerBoundary.handle={text:'SECRET'};
  const p=projectConversation(raw,13);
  assert.doesNotMatch(JSON.stringify(p),/SECRET|arguments|toolPayload|items|handle/);
  assert.equal(sessionFromProjection(base,p).awaitingInput,true);
  assert.equal(sessionFromProjection(base,p).attentionKey,'request:7');
});

test('nested runtime and request replacements retain only allowed scalar metadata',()=>{
  let p=projectConversation(snapshot(),13);
  p=patchProjection(p,[{op:'replace',path:['threadRuntimeStatus'],value:{type:'active',activeFlags:['waitingOnUserInput'],body:'SECRET'}},
    {op:'add',path:['requests',0],value:{requestId:'req',method:'question',params:{text:'SECRET'}}}]);
  assert.equal(sessionFromProjection(base,p).attentionKey,'request:req');
  assert.equal(sessionFromProjection(base,p).awaitingInput,true);
  assert.doesNotMatch(JSON.stringify(p),/SECRET|params|body/);
  p=patchProjection(p,[{op:'add',path:['threadRuntimeStatus','payload'],value:{text:'SECRET'}}]);
  assert.doesNotMatch(JSON.stringify(p),/SECRET|payload/);
});

test('entity, island and entry replacement patches preserve ordered identity and discard bodies',()=>{
  let p=projectConversation(snapshot(),13);
  p=patchProjection(p,[{op:'add',path:['turnHistory','history','entitiesByKey','next'],value:{turnId:'next',status:'completed',body:'SECRET'}},
    {op:'add',path:['turnHistory','history','islands',0,'entries',2],value:{key:'next-entry',value:'next',text:'SECRET'}}]);
  assert.equal(sessionFromProjection(base,p).attentionKey,'result:next');
  assert.doesNotMatch(JSON.stringify(p),/SECRET|next-entry|body/);
  p=patchProjection(p,[{op:'replace',path:['turnHistory','history','islands',0],value:{entries:[{value:'current',prompt:'SECRET'}],newerBoundary:{status:'exhausted',payload:'SECRET'}}}]);
  assert.equal(sessionFromProjection(base,p).attentionKey,'result:current');
  assert.doesNotMatch(JSON.stringify(p),/SECRET|payload|prompt/);
});

test('canonical boundary and entity removal patches clear completion identity immediately',()=>{
  let p=projectConversation(snapshot(),13);
  p=patchProjection(p,[{op:'replace',path:['turnHistory','history','islands',0,'newerBoundary','status'],value:'available'}]);
  assert.equal(sessionFromProjection(base,p).attentionKey,null);
  p=patchProjection(p,[{op:'replace',path:['turnHistory','history','islands',0,'newerBoundary','status'],value:'exhausted'},
    {op:'remove',path:['turnHistory','history','entitiesByKey','current']}]);
  assert.equal(sessionFromProjection(base,p).attentionKey,null);
});

test('whole-history and root replacement keep local protocol selection and sanitize at every level',()=>{
  const raw=snapshot() as any;raw.streamVersion=11;raw.prompt='SECRET';
  let p=patchProjection(projectConversation(snapshot(),13),[{op:'replace',path:[],value:raw}]);
  assert.equal(p.streamVersion,13);assert.doesNotMatch(JSON.stringify(p),/SECRET/);
  p=patchProjection(p,[{op:'replace',path:['turnHistory','history'],value:{...raw.turnHistory.history,body:'SECRET'}},
    {op:'replace',path:['streamVersion'],value:11}]);
  assert.equal(p.streamVersion,13);assert.doesNotMatch(JSON.stringify(p),/SECRET/);
  assert.throws(()=>patchProjection(p,[{op:'remove',path:[]}]),/root/);
});

test('prototype and malformed array paths are rejected even underneath discarded content',()=>{
  const p=projectConversation(snapshot(),13);
  for(const path of [ ['__proto__','polluted'],['items','constructor','x'],
    ['turnHistory','history','entitiesByKey','toString','prototype'],['turns',-1],['turns',0.5],['turns','bad-index'] ])
    assert.throws(()=>patchProjection(p,[{op:'add',path,value:'SECRET'}]),/Unsafe|Unsupported/);
  const raw=snapshot();raw.turnHistory.history.islands[0].entries[1].value='toString';
  assert.equal(session(raw).attentionKey,null);
  raw.turnHistory.history.islands[0].entries[1].value='__proto__';assert.equal(session(raw).attentionKey,null);
});

test('malformed structural patch values throw instead of silently changing array positions',()=>{
  const p=projectConversation(snapshot(),13);
  for(const patch of [
    {op:'add',path:['turnHistory','history','islands',0,'entries',1],value:'invalid'},
    {op:'replace',path:['threadRuntimeStatus','activeFlags'],value:{text:'SECRET'}},
    {op:'replace',path:['turnHistory','history','islands'],value:null},
    {op:'replace',path:['requests',0,'id'],value:{text:'SECRET'}},
    {op:'replace',path:['hasUnreadTurn'],value:'true'},
  ]) assert.throws(()=>patchProjection(p,[patch]),/Unsupported|Cannot/);
});

test('array removal keeps later entry indexes aligned and empty newest island has no result',()=>{
  let p=projectConversation(snapshot(),13);
  p=patchProjection(p,[{op:'remove',path:['turnHistory','history','islands',0,'entries',0]}]);
  assert.equal(sessionFromProjection(base,p).attentionKey,'result:current');
  p=patchProjection(p,[{op:'remove',path:['turnHistory','history','islands',0,'entries',0]}]);
  assert.equal(sessionFromProjection(base,p).attentionKey,null);
});

test('snapshot validator accepts partial head metadata but rejects malformed selected shapes',()=>{
  const raw=snapshot();raw.turnHistory.history.islands[0].newerBoundary.status='available';
  assert.doesNotThrow(()=>validateConversation(raw,13));
  for(const bad of [ {...raw,id:undefined}, {...raw,threadRuntimeStatus:{type:'future-state'}},
    {...raw,requests:{}}, {...raw,turns:null}, {...raw,hasUnreadTurn:'yes'},
    {...raw,turnHistory:{kind:'canonical',history:{entitiesByKey:{},islands:[{entries:null}]}}} ])
    assert.throws(()=>validateConversation(bad,13));
});

test('v13 patches cannot hide missing required metadata behind projection defaults',()=>{
  const p=projectConversation(snapshot(),13);
  for(const field of ['requests','turns','threadRuntimeStatus'])
    assert.throws(()=>patchProjection(p,[{op:'remove',path:[field]}]),/Missing/);
  for(const field of ['requests','turns']) {
    const raw=snapshot() as any;delete raw[field];
    assert.throws(()=>patchProjection(p,[{op:'replace',path:[],value:raw}]),/Missing/);
  }
});

test('losing a canonical history marker cannot fall back to stale legacy results',()=>{
  const raw=snapshot() as any;delete raw.turnHistory.kind;
  assert.equal(session(raw).attentionKey,null);
  assert.throws(()=>patchProjection(projectConversation(snapshot(),13),[{op:'remove',path:['turnHistory','kind']}]),/Missing/);
  assert.throws(()=>patchProjection(projectConversation(snapshot(),13),[{op:'remove',path:['turnHistory']}]),/Missing/);
});

test('array length replacement clears removed latest entries rather than leaving a stale result',()=>{
  const p=patchProjection(projectConversation(snapshot(),13),[
    {op:'replace',path:['turnHistory','history','islands',0,'entries','length'],value:0}]);
  assert.equal(sessionFromProjection(base,p).attentionKey,null);
});

test('nested canonical-to-legacy switch resynchronizes instead of reusing stale turns',()=>{
  const p=projectConversation(snapshot(),13);
  assert.throws(()=>patchProjection(p,[{op:'replace',path:['turnHistory','kind'],value:'legacy'}]),/changed/);
  const fresh=snapshot() as any;fresh.turnHistory={kind:'legacy'};
  fresh.turns=[{turnId:'fresh',status:'completed',turnStartedAtMs:1}];
  const replaced=patchProjection(p,[{op:'replace',path:[],value:fresh}]);
  assert.equal(sessionFromProjection(base,replaced).attentionKey,'result:fresh');
});

test('array length add/remove cannot be mistaken for an insertion or removal at index zero',()=>{
  const p=projectConversation(snapshot(),13);
  for(const op of ['add','remove'])
    assert.throws(()=>patchProjection(p,[{op,path:['turnHistory','history','islands',0,'entries','length'],value:0}]),/length operation/);
});
