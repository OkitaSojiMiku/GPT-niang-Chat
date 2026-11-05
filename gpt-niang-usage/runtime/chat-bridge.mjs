import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {createHash,randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {atomicJson} from './usage.mjs';
import {ChatAppClient,modelsFromCatalog,finalReply,userText} from './chat-app-client.mjs';

export const chatDirectory=appDir=>path.join(appDir,'local-codex-chat-state');
export function chatEndpoint(appDir){return '\\\\.\\pipe\\gpt-niang-chat-'+createHash('sha256').update(path.resolve(appDir).toLowerCase()).digest('hex').slice(0,24);}
const readJson=file=>{try{return JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));}catch{return null;}};

export class CodexChatBridge{
  constructor(client,{appDir,now=()=>Date.now()}={}){
    this.client=client;this.directory=chatDirectory(appDir);this.now=now;this.state={connected:false,threads:[],models:[],selectedThreadId:'',selectedModel:'',busy:false,reply:'',replyThreadId:'',revision:0,error:'',status:'正在连接 Codex…'};
    this.preferences=readJson(path.join(this.directory,'preferences.json'))||{};
    this.state.selectedThreadId=this.preferences.threadId||'';this.state.selectedModel=this.preferences.model||'';
    this.lastList=0;this.lastRead=0;this.inflight=readJson(path.join(this.directory,'active.json'));this.handled=new Set();
    if(this.inflight?.id&&this.inflight?.threadId&&typeof this.inflight.prompt==='string'){
      this.state.busy=true;this.state.requestId=this.inflight.id;this.state.lastCommandId=this.inflight.id;this.state.replyThreadId=this.inflight.threadId;
    }else this.inflight=null;
  }
  publish(){
    this.state.at=this.now();this.state.pid=process.pid;this.state.revision++;
    try{atomicJson(path.join(this.directory,'state.json'),this.state);}catch(error){if(!['EPERM','EBUSY','EACCES'].includes(error.code))throw error;}
  }
  save(){atomicJson(path.join(this.directory,'preferences.json'),{threadId:this.state.selectedThreadId,model:this.state.selectedModel});}
  async connect(){
    await this.client.start();this.state.models=modelsFromCatalog(this.client.catalog||[]);this.state.connected=true;
    if(this.state.selectedModel&&!this.state.models.some(m=>m.id===this.state.selectedModel))this.state.selectedModel='';
    await this.refreshThreads();this.state.status=this.inflight?'正在恢复等待中的回复…':'请选择一个 Codex 会话';this.publish();
  }
  async refreshThreads(){
    const result=await this.client.call('list_threads',{limit:50});
    this.state.threads=[...(result.pinnedThreads||[]),...(result.threads||[])].filter(t=>t.kind==='codex'&&(!t.hostId||t.hostId==='local')).map(t=>({id:t.id,title:t.title||'未命名会话',status:typeof t.status==='string'?t.status:t.status?.type||'unknown',hostId:t.hostId||'local'}));
    if(this.state.selectedThreadId&&!this.state.threads.some(t=>t.id===this.state.selectedThreadId)&&!this.inflight){this.state.selectedThreadId='';this.state.reply='';this.state.replyThreadId='';this.save();}
    this.lastList=this.now();
  }
  async read(threadId){return this.client.call('read_thread',{threadId,hostId:'local',turnLimit:3,includeOutputs:true,maxOutputCharsPerItem:20000});}
  async command(command){
    if(!command||typeof command.id!=='string'||this.handled.has(command.id))return;
    this.handled.add(command.id);if(this.handled.size>300)this.handled.delete(this.handled.values().next().value);
    this.state.lastCommandId=command.id;this.state.error='';
    try{
      if(!this.state.connected)throw new Error('聊天连接已断开，请在 Codex 中让 GPT 娘刷新一次额度后重试');
      if(!Number.isFinite(command.at)||Math.abs(this.now()-command.at)>30000)throw new Error('操作已过期，请重新点击；消息没有自动重发');
      if(command.type==='refresh'){await this.refreshThreads();}
      else if(command.type==='select'){
        if(this.inflight)throw new Error('当前回复尚未完成，请稍后切换会话');
        if(!this.state.threads.some(t=>t.id===command.threadId))throw new Error('请从菜单中选择一个已有的本地 Codex 会话');
        this.state.selectedThreadId=command.threadId;this.state.reply='';this.state.replyThreadId='';this.state.truncated=false;this.state.status='已连接会话';this.save();this.lastRead=0;
      }else if(command.type==='model'){
        if(this.inflight)throw new Error('当前回复尚未完成，请稍后切换模型');
        if(command.model!==''&&!this.state.models.some(m=>m.id===command.model))throw new Error('当前客户端不支持此模型');
        this.state.selectedModel=command.model;this.save();this.state.status=command.model?'下次发送使用 '+command.model:'下次发送沿用会话模型';
      }else if(command.type==='send'){
        if(this.inflight)throw new Error('正在等待回复，请勿重复发送');
        const thread=this.state.threads.find(t=>t.id===command.threadId&&t.id===this.state.selectedThreadId);
        if(!thread)throw new Error('先在设置 → Codex 聊天 → 选择会话');
        if(typeof command.prompt!=='string'||!command.prompt.trim()||command.prompt.length>20000)throw new Error('请输入 1～20000 字的消息');
        const model=command.model??this.state.selectedModel;
        if(model&&!this.state.models.some(m=>m.id===model))throw new Error('所选模型暂不可用，请重新选择');
        const before=await this.read(thread.id);
        if(before.thread?.status?.type!=='idle'&&before.thread?.status?.type!=='notLoaded'&&before.thread?.status?.type!=='unloaded')throw new Error('该会话正在处理或等待确认，请等它结束后发送');
        const startedAt=this.now();
        this.inflight={id:command.id,threadId:thread.id,baseline:before.turns?.[0]?.id,prompt:command.prompt.trim(),startedAt};
        atomicJson(path.join(this.directory,'active.json'),this.inflight);
        this.state.busy=true;this.state.reply='';this.state.truncated=false;this.state.replyThreadId=thread.id;this.state.status='正在发送…';this.state.requestId=command.id;this.publish();
        // Capture the target and model before sending. Never resend automatically on error.
        const args={threadId:thread.id,hostId:'local',prompt:command.prompt.trim()};if(model)args.model=model;
        try{await this.client.call('send_message_to_thread',args);this.state.status='Codex 正在回复…';}
        catch(error){this.finishPending();throw new Error(error.message+'；请检查原会话后再决定是否重发');}
        this.lastRead=0;
      }else throw new Error('无法识别此操作');
    }catch(error){this.state.error=error.message;this.state.status=error.message;}
    this.publish();
  }
  async poll(){
    if(!this.state.connected)return;
    if(this.now()-this.lastList>15000&&!this.inflight)await this.refreshThreads();
    const target=this.inflight?.threadId||this.state.selectedThreadId;
    if(!target||this.now()-this.lastRead<(this.inflight?1000:4000))return;
    this.lastRead=this.now();const result=await this.read(target);
    if(this.inflight){
      const pending=this.inflight;
      const turn=(result.turns||[]).find(t=>t.id!==pending.baseline&&userText(t)===pending.prompt&&(t.startedAt==null||(t.startedAt<1e12?t.startedAt*1000:t.startedAt)>=pending.startedAt-10000));
      if(turn){
        if(turn.status==='completed'){
          const reply=finalReply(turn);this.state.reply=reply||'该轮已完成，未返回文字回复。';this.state.replyThreadId=target;this.state.replyRequestId=pending.id;this.state.status='回复完成';this.finishPending();this.lastList=0;
          this.state.truncated=(turn.items||[]).some(i=>i.textTruncated===true||i.truncated===true);
        }else if(['failed','interrupted','cancelled'].includes(turn.status)){
          this.state.reply=finalReply(turn);this.state.status=turn.error?.message||'本轮已中断或失败，请检查原会话';this.state.error=this.state.status;this.finishPending();
        }else if(/input|approval|blocked/i.test([result.thread?.status?.type,...(result.thread?.status?.activeFlags||[])].join(' ')))this.state.status='会话需要确认，请在原会话中处理后继续';
      }
      if(this.inflight&&this.now()-pending.startedAt>30*60*1000){this.state.error='等待超过 30 分钟，请检查原会话；消息不会自动重发';this.state.status=this.state.error;this.finishPending();}
    }else{
      const completed=(result.turns||[]).find(t=>t.status==='completed');
      const text=finalReply(completed);
      if(text){this.state.reply=text;this.state.replyThreadId=target;this.state.status='最近一次回复';}
    }
    this.publish();
  }
  finishPending(){this.inflight=null;this.state.busy=false;try{fs.unlinkSync(path.join(this.directory,'active.json'));}catch{}}
}

async function run(){
  const appDir=path.resolve(process.argv[2]||path.join(path.dirname(fileURLToPath(import.meta.url)),'..'));
  const directory=chatDirectory(appDir);fs.mkdirSync(directory,{recursive:true});
  let attachment=null;
  // Rebind to a newly started desktop instance without ever saving its pipe capability.
  const lock=net.createServer(socket=>{
    let buffer='';socket.setTimeout(3000,()=>socket.destroy());
    socket.on('error',()=>{});socket.on('data',chunk=>{
      buffer+=chunk.toString('utf8');if(buffer.length>16000){socket.destroy();return;}
      if(!buffer.includes('\n'))return;
      try{
        const value=JSON.parse(buffer.split('\n')[0]);
        if(value.type==='attach'&&typeof value.pipe==='string'&&value.pipe.startsWith('\\\\.\\pipe\\')&&typeof value.threadId==='string'&&value.threadId){attachment=value;socket.end('attached\n');}
        else socket.destroy();
      }catch{socket.destroy();}
    });
  });
  const acquired=await new Promise((resolve,reject)=>{lock.once('error',e=>e.code==='EADDRINUSE'?resolve(false):reject(e));lock.listen(chatEndpoint(appDir),()=>resolve(true));});
  const caller=process.env.CODEX_THREAD_ID||process.argv[3]||readJson(path.join(directory,'context.json'))?.threadId;
  if(!acquired){
    if(caller&&process.env.CODEX_APP_TOOLS_PIPE_PATH){
      await new Promise(resolve=>{
        const socket=net.createConnection(chatEndpoint(appDir));socket.setTimeout(3000,()=>{socket.destroy();resolve();});socket.once('error',()=>resolve());socket.once('close',()=>resolve());
        socket.once('connect',()=>socket.write(JSON.stringify({type:'attach',pipe:process.env.CODEX_APP_TOOLS_PIPE_PATH,threadId:caller,node:process.env.CODEX_MCP_NODE_PATH||process.execPath})+'\n'));
        socket.once('data',()=>{socket.end();resolve();});
      });
    }
    return;
  }
  if(caller)atomicJson(path.join(directory,'context.json'),{threadId:caller});
  let client,bridge;
  try{
    client=new ChatAppClient({threadId:caller});bridge=new CodexChatBridge(client,{appDir});
    // Old pending commands are never replayed after a crash or restart.
    for(const name of fs.readdirSync(directory).filter(n=>/^request-[\w-]+\.json$/.test(n)))fs.renameSync(path.join(directory,name),path.join(directory,name+'.expired'));
    await bridge.connect();
    let running=false;
    const timer=setInterval(async()=>{
      if(running)return;running=true;
      try{
        if(attachment){
          const next=attachment;attachment=null;
          if(client.disconnected||!bridge.state.connected||next.pipe!==client.env.CODEX_APP_TOOLS_PIPE_PATH){
            bridge.state.connected=false;client.close();client=new ChatAppClient({threadId:next.threadId,env:{...process.env,CODEX_APP_TOOLS_PIPE_PATH:next.pipe,CODEX_MCP_NODE_PATH:next.node}});
            await client.start();bridge.client=client;bridge.state.connected=true;bridge.state.error='';bridge.state.models=modelsFromCatalog(client.catalog||[]);
            bridge.state.status=bridge.inflight?'正在恢复等待中的回复…':'已重新连接桌面客户端';bridge.lastList=0;bridge.lastRead=0;
          }
        }
        const names=fs.readdirSync(directory).filter(n=>/^request-[\w-]+\.json$/.test(n)).sort();
        for(const name of names){
          const file=path.join(directory,name);const command=readJson(file);const claimed=file+'.processing';
          try{fs.renameSync(file,claimed);}catch{continue;}
          await bridge.command(command);try{fs.unlinkSync(claimed);}catch{}
        }
        await bridge.poll();bridge.publish();
      }catch(error){bridge.state.error=error.message;bridge.state.status=error.message;if(client.disconnected||/断开|连接超时|pipe closed/i.test(error.message))bridge.state.connected=false;bridge.publish();}
      finally{running=false;}
    },250);
    const stop=()=>{clearInterval(timer);client.close();lock.close();process.exit(0);};
    process.on('SIGTERM',stop);process.on('SIGINT',stop);
  }catch(error){
    atomicJson(path.join(directory,'state.json'),{connected:false,busy:false,threads:[],models:[],error:error.message,status:error.message,at:Date.now(),pid:process.pid,revision:randomUUID()});
    client?.close();lock.close();process.exitCode=1;
  }
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))await run();
