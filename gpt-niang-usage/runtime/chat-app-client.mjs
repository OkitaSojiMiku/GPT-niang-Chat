import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {spawn} from 'node:child_process';
import readline from 'node:readline';

// Use the installed first-party MCP server, never credentials or private HTTP endpoints.
export function findAppToolsServer(env=process.env){
  const root=path.join(env.CODEX_HOME||path.join(env.USERPROFILE||os.homedir(),'.codex'),'plugins','cache','openai-bundled','codex-app-tools');
  const candidates=fs.readdirSync(root).map(name=>path.join(root,name,'server.mjs')).filter(file=>fs.existsSync(file));
  candidates.sort((a,b)=>fs.statSync(b).mtimeMs-fs.statSync(a).mtimeMs);
  if(!candidates.length)throw new Error('未找到桌面客户端的会话连接组件');
  return candidates[0];
}

const allowedTools=new Set(['list_threads','read_thread','send_message_to_thread']);
export class ChatAppClient{
  constructor({threadId,serverPath,env=process.env,timeoutMs=20000}={}){
    if(!threadId)throw new Error('缺少 Codex 会话连接上下文，请在 Codex 中刷新一次 GPT 娘额度');
    this.threadId=threadId;this.serverPath=serverPath;this.env=env;this.timeoutMs=timeoutMs;this.pending=new Map();this.sequence=0;
  }
  async start(){
    if(this.child)return;
    if(!this.env.CODEX_APP_TOOLS_PIPE_PATH)throw new Error('请在 Codex 中刷新一次 GPT 娘额度，连接桌面聊天');
    const server=this.serverPath||findAppToolsServer(this.env);
    this.child=spawn(this.env.CODEX_MCP_NODE_PATH||process.execPath,[server],{windowsHide:true,env:this.env,stdio:['pipe','pipe','pipe']});
    this.lines=readline.createInterface({input:this.child.stdout});
    this.lines.on('line',line=>{
      let message;try{message=JSON.parse(line);}catch{return;}
      const pending=this.pending.get(message.id);if(!pending)return;
      this.pending.delete(message.id);clearTimeout(pending.timer);
      message.error?pending.reject(new Error(message.error.message)):pending.resolve(message.result);
    });
    const failed=()=>{this.disconnected=true;this.fail(new Error('桌面会话连接已断开，请在 Codex 中刷新 GPT 娘额度后重试'));};
    this.child.on('error',failed);this.child.on('exit',failed);this.child.stdin.on('error',failed);this.child.stderr.on('data',()=>{});
    await this.request('initialize',{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'gpt-niang-codex-chat',version:'0.1.0'}});
    this.child.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
    const catalog=await this.request('tools/list',{});
    this.catalog=catalog.tools;this.disconnected=false;
  }
  request(method,params){
    return new Promise((resolve,reject)=>{
      if(!this.child||this.child.stdin.destroyed||this.disconnected){reject(new Error('桌面会话连接已断开，请在 Codex 中刷新 GPT 娘额度后重试'));return;}
      const id=++this.sequence;
      const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('桌面连接超时；若刚发送过消息，请先检查会话，避免重复发送'));},this.timeoutMs);
      this.pending.set(id,{resolve,reject,timer});
      this.child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');
    });
  }
  async call(name,args){
    if(!allowedTools.has(name))throw new Error('此连接只允许列出、读取和续接 Codex 会话');
    const result=await this.request('tools/call',{name,arguments:args,_meta:{'openai/threadId':this.threadId}});
    const text=result.content?.filter(item=>item.type==='text').map(item=>item.text).join('\n');
    if(result.isError)throw new Error(text||'桌面会话操作失败');
    try{return JSON.parse(text);}catch{throw new Error('桌面会话返回了无法识别的数据');}
  }
  fail(error){for(const item of this.pending.values()){clearTimeout(item.timer);item.reject(error);}this.pending.clear();}
  close(){this.disconnected=true;this.fail(new Error('连接已关闭'));this.lines?.close();this.child?.stdin.end();this.child?.kill();this.child=null;}
}

export function modelsFromCatalog(catalog){
  const tool=catalog.find(item=>item.name==='send_message_to_thread');
  const description=tool?.inputSchema?.properties?.model?.description||'';
  return [...new Set(description.match(/\bgpt-[\da-z]+(?:[.-][\da-z]+)*/g)||[])].map(id=>({id,label:id.replace(/^gpt-/,'GPT-').replace(/-(sol|astra|luna|terra)$/,(_,word)=>' '+word[0].toUpperCase()+word.slice(1))}));
}

export function finalReply(turn){
  const messages=(turn?.items||[]).filter(item=>item.type==='agentMessage'&&typeof item.text==='string'&&item.text.trim()&&!item.text.includes('::chatgpt-content-reference'));
  const finals=messages.filter(item=>item.phase==='final_answer');
  const chosen=finals.length?finals:messages.filter(item=>!item.phase).slice(-1);
  return chosen.map(item=>item.text).join('\n\n');
}

export function userText(turn){
  const direct=(turn?.items||[]).filter(item=>item.type==='userMessage').flatMap(item=>item.content||[]).filter(item=>item.type==='text').map(item=>item.text).join('\n').trim();
  if(direct)return direct;
  // Desktop follow-ups arrive as an explicit tool message in the same existing thread.
  for(const item of turn?.items||[]){
    if(item.type!=='functionCallOutput'||item.name!=='send_message_to_thread')continue;
    const text=item.output?.text;if(typeof text!=='string'||!text.startsWith('<codex_delegation>'))continue;
    const start=text.indexOf('<input>'),end=text.lastIndexOf('</input>');
    if(start>=0&&end>start)return text.slice(start+7,end).trim();
  }
  return '';
}
