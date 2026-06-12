#!/usr/bin/env node
/**
 * Dynamic VM Start Intercept Patch
 *
 * Discovers the VM start function by its semantic signature (the [VM:start]
 * log string and 4-param async function pattern), then injects a Linux
 * bubblewrap session block before the original function body.
 *
 * Version-resilient — discovers identifiers at build time, not hardcoded.
 */
const fs = require('fs');
const path = require('path');

const EXTRACTED_DIR = process.argv[2] || '/tmp/app-extracted';
const INDEX_JS_PATH = path.join(EXTRACTED_DIR, '.vite/build/index.js');

console.log('=== Dynamic Patch: VM Start Intercept ===\n');

let content = fs.readFileSync(INDEX_JS_PATH, 'utf8');

// Discover the VM start function. It is the 4-param async function whose body
// emits the `[VM:start]` log. Rather than pin the exact body preamble (which is
// refactored between versions — e.g. cleanup loops were added before the
// Date.now()/info() sequence), locate the first `[VM:start]` and scan back to the
// nearest enclosing 4-param async declaration. We inject the Linux block right
// after that function's opening brace, leaving the original body untouched.
const vmStartIdx = content.indexOf('[VM:start]');
if (vmStartIdx === -1) {
  console.error('  ERROR: Could not find [VM:start] log string');
  process.exit(1);
}

const declRe = /async function (\w+)\((\w+),(\w+),(\w+),(\w+)\)\{/g;
let m, decl = null;
while ((m = declRe.exec(content)) !== null) {
  if (m.index >= vmStartIdx) break;
  decl = m;
}

if (!decl) {
  console.error('  ERROR: Could not find a 4-param async function before [VM:start]');
  process.exit(1);
}

// Sanity check: the discovered declaration should be the immediate encloser —
// no other function may open between it and the [VM:start] log.
const bodyHead = content.slice(decl.index + decl[0].length, vmStartIdx);
if (bodyHead.includes('async function ') || (vmStartIdx - decl.index) > 4000) {
  console.error('  ERROR: Nearest 4-param async decl is not the [VM:start] encloser');
  console.error(`         (name=${decl[1]}, distance=${vmStartIdx - decl.index})`);
  process.exit(1);
}

const funcName = decl[1];
const params = [decl[2], decl[3], decl[4], decl[5]];
const declStr = decl[0]; // e.g. async function ZBr(A,e,t,i){

console.log(`  Found VM start function: ${funcName}(${params.join(',')})`);

// Discover the status dispatch: the readiness notifier called immediately before
// the `lam_vm_startup_completed` analytics event (historically `WORD(WORD.Ready)`,
// now a zero-arg notifier such as `orA()`). Best-effort; falls back to a log.
let statusDispatch = 'console.log("[Cowork Linux] Ready")';
const readyArgMatch = content.match(/(\w+)\((\w+)\.Ready\),\w+\("lam_vm_startup_completed"/);
const readyCallMatch = content.match(/(\w+\(\)),\w+\("lam_vm_startup_completed"/);
if (readyArgMatch) {
  statusDispatch = `${readyArgMatch[1]}(${readyArgMatch[2]}.Ready)`;
  console.log(`  Found status dispatch: ${statusDispatch}`);
} else if (readyCallMatch) {
  statusDispatch = readyCallMatch[1];
  console.log(`  Found status dispatch: ${statusDispatch}`);
} else {
  console.log('  WARNING: Could not find status dispatch, using console.log fallback');
}

// Build the injection block: the original function declaration, immediately
// followed by the Linux short-circuit. The original body is left in place after
// it (runs for non-Linux, or when a vmInstance already exists).
const injection = `${declStr}
  if(process.platform==="linux"&&global.__linuxCowork&&!global.__linuxCowork.vmInstance){
    console.log("[Cowork Linux] Creating bubblewrap session");
    const {manager}=global.__linuxCowork;
    try {
      const {randomUUID}=require('crypto');
      const nodePath=require('path');
      const nodeFs=require('fs');
      const sessionId=randomUUID();
      manager.createSession(sessionId);
      console.log("[Cowork Linux] Session created:",sessionId);
      // Process event sink (installed by the app via setEventCallbacks) and a
      // per-id process registry so writeStdin/kill/isProcessRunning work by id.
      let __cbs={};
      const __procs=new Map();
      const __emit=(name,...a)=>{try{if(typeof __cbs[name]==="function")__cbs[name](...a)}catch(e){}};
      // The app spawns the agent as the bare command "claude"; resolve it to the
      // downloaded CCD binary under userData (prefer a .verified version).
      const __resolveCommand=(cmd)=>{
        if(cmd!=="claude")return cmd;
        try{
          const base=nodePath.join(oA.app.getPath("userData"),"claude-code");
          const vers=nodeFs.readdirSync(base).filter(d=>{try{return nodeFs.existsSync(nodePath.join(base,d,"claude"))}catch(e){return false}}).sort();
          const pick=vers.slice().reverse().find(d=>nodeFs.existsSync(nodePath.join(base,d,".verified")))||vers[vers.length-1];
          if(pick)return nodePath.join(base,pick,"claude");
        }catch(e){console.error("[Cowork Linux] claude binary resolve failed:",e.message)}
        return cmd;
      };
      const vmInstance={
        sessionId,
        isConnected:()=>true,
        isGuestConnected:()=>Promise.resolve(true),
        isProcessRunning:(id)=>{
          if(id==="__heartbeat_ping__")return Promise.resolve({running:true});
          const r=__procs.get(id);
          return Promise.resolve({running:!!(r&&r.running),exitCode:r?r.exitCode:void 0});
        },
        startVM:async()=>{},
        stopVM:async()=>{},
        installSdk:async()=>{},
        setEventCallbacks:(onStdout,onStderr,onExit,onError,onNetworkStatus,onApiReachability,onStartupStep)=>{
          __cbs={onStdout,onStderr,onExit,onError,onNetworkStatus,onApiReachability,onStartupStep};
        },
        // Full VM-client spawn signature:
        // id,name,command,args,cwd,env,additionalMounts,isResume,allowedDomains,oneShot,mountSkeletonHome,oauthToken
        spawn:(id,name,command,args,cwd,env,additionalMounts,isResume,allowedDomains,oneShot,mountSkeletonHome,oauthToken)=>{
          const resolved=__resolveCommand(command||"claude");
          const procEnv=Object.assign({},process.env,env||{});
          if(oauthToken)procEnv.CLAUDE_CODE_OAUTH_TOKEN=oauthToken;
          // Secret-safe spawn log: env KEYS and mount points only, never values/tokens.
          console.log("[Cowork Linux] spawn "+JSON.stringify({id:id,name:name,command:command,resolved:resolved,args:args||[],cwd:cwd||null,oneShot:!!oneShot,hasOauthToken:!!oauthToken,envKeys:Object.keys(env||{}),mounts:additionalMounts?Object.keys(additionalMounts):[]}));
          const procInfo=manager.spawnSandboxed(sessionId,resolved,args||[],{cwd:cwd||void 0,env:procEnv,additionalMounts:additionalMounts||void 0,stdio:["pipe","pipe","pipe"]});
          const child=procInfo.child;
          const rec={id,proc:procInfo,running:true,exitCode:void 0};
          __procs.set(id,rec);
          if(child.stdout)child.stdout.on("data",d=>__emit("onStdout",id,d.toString()));
          if(child.stderr)child.stderr.on("data",d=>__emit("onStderr",id,d.toString()));
          child.on("exit",(code,signal)=>{rec.running=false;rec.exitCode=code;console.log("[Cowork Linux] proc "+id+" exited code="+code+" signal="+(signal||"none"));__emit("onExit",id,code,signal||null,0)});
          child.on("error",err=>__emit("onError",id,String(err&&err.message||err),false));
          return Promise.resolve({id,processId:procInfo.id});
        },
        writeStdin:(id,data)=>{const r=__procs.get(id);if(r&&r.proc.child&&r.proc.child.stdin)try{r.proc.child.stdin.write(data)}catch(e){}return Promise.resolve()},
        kill:(id,signal)=>{const r=__procs.get(id);if(r&&r.proc.child&&!r.proc.child.killed)try{r.proc.child.kill(signal||"SIGTERM")}catch(e){}return Promise.resolve()},
        executeCommand:(cmd)=>manager.spawnSandboxed(sessionId,__resolveCommand(cmd.command),cmd.args||[]),
        addMount:(hostPath)=>manager.addMount(sessionId,hostPath),
        dispose:()=>{manager.destroySession(sessionId);delete global.__linuxCowork.vmInstance},
        addApprovedOauthToken:()=>Promise.resolve(),
        exec:(command)=>manager.spawnSandboxed(sessionId,'/bin/sh',['-c',command]),
        mkdir:()=>Promise.resolve(),
        readFile:(p,enc)=>Promise.resolve(require('fs').readFileSync(p,enc||'utf8')),
        writeFile:(p,data,enc)=>{require('fs').writeFileSync(p,data,enc||'utf8');return Promise.resolve()},
        rm:()=>Promise.resolve(),
        configure:async()=>{},
        createVM:async()=>{},
        getVmProcessId:()=>'cowork-linux-'+sessionId.slice(0,8),
        connect:async()=>{},
        disconnect:async()=>{manager.destroySession(sessionId)},
      };
      global.__linuxCowork.vmInstance=vmInstance;
      try{${statusDispatch}}catch(e){console.log("[Cowork Linux] Status dispatch note:",e.message)}
      console.log("[Cowork Linux] VM instance ready");
      return vmInstance;
    }catch(e){console.error("[Cowork Linux] Session creation failed:",e)}
  }
  `;

// Inject right after the function's opening brace. The declaration is unique, so
// String.replace (first occurrence) is safe and leaves the original body intact.
if (!content.includes(declStr)) {
  console.error('  ERROR: Could not locate original function for replacement');
  process.exit(1);
}

content = content.replace(declStr, injection);
fs.writeFileSync(INDEX_JS_PATH, content);

// Verify
const patched = fs.readFileSync(INDEX_JS_PATH, 'utf8');
if (!patched.includes('global.__linuxCowork.vmInstance=vmInstance')) {
  console.error('  ERROR: Verification failed — injection not found in output');
  process.exit(1);
}

console.log('  VM start intercept applied successfully\n');
