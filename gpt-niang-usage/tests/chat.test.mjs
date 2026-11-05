import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {CodexChatBridge,chatDirectory} from '../runtime/chat-bridge.mjs';
import {finalReply,modelsFromCatalog,userText} from '../runtime/chat-app-client.mjs';
const testRoot=os.tmpdir();
function fixture(){
 const directory=fs.mkdtempSync(path.join(testRoot,'gpt-niang-bridge-'));let now=1792830000000;
 const calls=[];let read={thread:{status:{type:'idle'}},turns:[{id:'old',status:'completed',items:[{type:'agentMessage',phase:'final_answer',text:'旧回复'}]}]};
 const client={catalog:[{name:'send_message_to_thread',inputSchema:{properties:{model:{description:'Models: gpt-6.1-sol (Available), gpt-6-luna (Available)'}}}}],async start(){},async call(name,args){calls.push({name,args});if(name==='list_threads')return {threads:[{kind:'codex',hostId:'local',id:'a',title:'本地会话',status:'idle'},{kind:'chatgpt',id:'cloud',title:'云端会话'},{kind:'codex',hostId:'other',id:'remote'}]};if(name==='read_thread')return read;return {ok:true};}};
 const bridge=new CodexChatBridge(client,{appDir:directory,now:()=>now});
 let sequence=0;const command=(type,fields={})=>({id:'r'+(++sequence),at:now,type,...fields});
 return {bridge,calls,command,setRead:value=>read=value,advance:value=>now+=value,cleanup:()=>{const relative=path.relative(testRoot,path.resolve(directory));if(!relative||relative==='..'||relative.startsWith('..'+path.sep)||path.isAbsolute(relative))throw new Error('Test directory escaped its root');fs.rmSync(directory,{recursive:true,force:true});}};
}
test('catalog models and final-only extraction do not expose reasoning or commentary',()=>{
 assert.equal(finalReply({items:[{type:'agentMessage',phase:'commentary',text:'过程'},{type:'reasoning',text:'私有推理'},{type:'agentMessage',phase:'final_answer',text:'最终答复'}]}),'最终答复');
 assert.equal(finalReply({items:[{type:'agentMessage',text:'::chatgpt-content-reference{index="0"}'}]}),'');
 assert.deepEqual(modelsFromCatalog([{name:'send_message_to_thread',inputSchema:{properties:{model:{description:'gpt-6.1-sol and gpt-6-luna'}}}}]).map(m=>m.id),['gpt-6.1-sol','gpt-6-luna']);
 assert.equal(userText({items:[{type:'functionCallOutput',name:'send_message_to_thread',output:{text:'<codex_delegation>\n<source_thread_id>source</source_thread_id>\n<input>实际消息</input>\n</codex_delegation>'}}]}),'实际消息');
});
test('only existing local Codex threads, validated models, one send per explicit command',async()=>{
 const f=fixture();try{
  await f.bridge.connect();assert.deepEqual(f.bridge.state.threads.map(t=>t.id),['a']);
  await f.bridge.command(f.command('select',{threadId:'cloud'}));assert.equal(f.bridge.state.selectedThreadId,'');
  await f.bridge.command(f.command('select',{threadId:'a'}));
  await f.bridge.command(f.command('model',{model:'gpt-does-not-exist'}));assert.equal(f.bridge.state.selectedModel,'');
  await f.bridge.command(f.command('model',{model:'gpt-6-luna'}));
  const send=f.command('send',{threadId:'a',prompt:'你好',model:'gpt-6-luna'});await f.bridge.command(send);await f.bridge.command(send);
  assert.equal(f.calls.filter(c=>c.name==='send_message_to_thread').length,1);
  assert.deepEqual(f.calls.find(c=>c.name==='send_message_to_thread').args,{threadId:'a',hostId:'local',prompt:'你好',model:'gpt-6-luna'});
  await f.bridge.command(f.command('send',{threadId:'a',prompt:'不要重复'}));assert.equal(f.calls.filter(c=>c.name==='send_message_to_thread').length,1);
 }finally{f.cleanup();}
});
test('reply correlation ignores stale and unrelated turns and supports seconds timestamps',async()=>{
 const f=fixture();try{
  await f.bridge.connect();await f.bridge.command(f.command('select',{threadId:'a'}));
  const send=f.command('send',{threadId:'a',prompt:'只回复测试'});await f.bridge.command(send);
  f.setRead({thread:{status:{type:'idle'}},turns:[{id:'other',status:'completed',items:[{type:'userMessage',content:[{type:'text',text:'他的问题'}]},{type:'agentMessage',phase:'final_answer',text:'其他回复'}]}]});
  f.advance(1200);await f.bridge.poll();assert.equal(f.bridge.state.reply,'');assert.equal(f.bridge.state.busy,true);
  f.setRead({thread:{status:{type:'idle'}},turns:[{id:'new',startedAt:1792830001,status:'completed',items:[{type:'userMessage',content:[{type:'text',text:'只回复测试'}]},{type:'agentMessage',phase:'commentary',text:'过程不显示'},{type:'agentMessage',phase:'final_answer',text:'测试成功'}]}]});
  f.advance(1200);await f.bridge.poll();assert.equal(f.bridge.state.reply,'测试成功');assert.equal(f.bridge.state.busy,false);assert.equal(f.bridge.state.replyRequestId,send.id);
 }finally{f.cleanup();}
});
test('stale commands and active conversations never send, no automatic retry on uncertain failure',async()=>{
 const f=fixture();try{
  await f.bridge.connect();await f.bridge.command(f.command('select',{threadId:'a'}));
  const expired=f.command('send',{threadId:'a',prompt:'已过期'});f.advance(31000);await f.bridge.command(expired);
  assert.equal(f.calls.filter(c=>c.name==='send_message_to_thread').length,0);
  f.setRead({thread:{status:{type:'active'}},turns:[]});await f.bridge.command(f.command('send',{threadId:'a',prompt:'忙碌'}));
  assert.equal(f.calls.filter(c=>c.name==='send_message_to_thread').length,0);
  assert.ok(chatDirectory(testRoot).startsWith(testRoot));
 }finally{f.cleanup();}
});
