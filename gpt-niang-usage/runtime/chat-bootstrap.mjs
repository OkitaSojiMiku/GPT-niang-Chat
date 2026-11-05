import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {chatDirectory} from './chat-bridge.mjs';
import {atomicJson} from './usage.mjs';

let launched=false;
export function ensureCodexChatBridge(appDir,meta={}){
  if(!process.env.CODEX_APP_TOOLS_PIPE_PATH)return;
  const directory=chatDirectory(appDir);
  const nested=meta?.['codex/turn'];
  const threadId=meta?.['openai/threadId']||meta?.['openai/thread_id']||nested?.thread_id||process.env.CODEX_THREAD_ID;
  if(threadId)atomicJson(path.join(directory,'context.json'),{threadId});
  if(launched)return;
  launched=true;
  const child=spawn(process.execPath,[path.join(appDir,'runtime','chat-bridge.mjs'),appDir,...(threadId?[threadId]:[])],{windowsHide:true,detached:true,stdio:'ignore'});
  child.on('error',()=>{launched=false;});child.on('exit',()=>{launched=false;});child.unref();
}
