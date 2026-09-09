#!/bin/bash
# DDNet remote gaming stack for Codespaces (rootless, no frp: uses codespaces port forwarding)
exec > /tmp/bootstrap.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
H=/home/codespace
echo "== apt =="
sudo apt-get update -qq
sudo apt-get install -y -qq x11-utils xauth imagemagick libvulkan1 mesa-vulkan-drivers \
  xdotool openbox pulseaudio pulseaudio-utils wget curl unzip jq libxfont2 libnotify4 \
  libsdl2-2.0-0 libsdl2-mixer-2.0-0 libfreetype6 net-tools >/dev/null 2>&1

echo "== x11vnc + xvfb (X display + RFB server) =="
sudo apt-get install -y -qq xvfb x11vnc >/dev/null 2>&1
command -v x11vnc || echo "WARN x11vnc missing"
command -v Xvfb || echo "WARN Xvfb missing"

echo "== KasmVNC (Xvnc, веб-клиент слота — каждый слот = свой websocket 6911+slot) =="
KASM_DEB=/tmp/kasmvnc.deb
KASM_OS=$(grep -oE 'VERSION_ID="[0-9.]+"' /etc/os-release | grep -oE '[0-9.]+')
if [ ! -x /usr/bin/Xvnc ] || ! strings /usr/bin/Xvnc 2>/dev/null | grep -qi kasm; then
  case "$KASM_OS" in
    24.04) KASM_REL=noble;; 22.04) KASM_REL=jammy;; 20.04) KASM_REL=focal;; *) KASM_REL=jammy;;
  esac
  for dl in 1 2 3 4 5; do
    curl -sSL -o $KASM_DEB https://github.com/kasmtech/KasmVNC/releases/download/v1.5.0/kasmvncserver_${KASM_REL}_1.5.0_amd64.deb && break
    sleep 3
  done
  if [ ! -f $KASM_DEB ]; then echo "KASM-DL-FAIL"; fi
  for it in 1 2 3 4 5 6 7 8; do
    sudo -n apt-get install -y -qq -o DPkg::Lock::Timeout=120 -f >/dev/null 2>&1 || true
    sudo -n apt-get install -y -qq -o DPkg::Lock::Timeout=120 "$KASM_DEB" >/dev/null 2>&1 && break
    sudo -n dpkg --configure -a >/dev/null 2>&1 || true
    [ "$it" = 4 ] && sudo apt-get update -qq >/dev/null 2>&1 || true
    sleep 10
  done
  rm -f $KASM_DEB
fi
if [ -x /usr/bin/Xvnc ] && strings /usr/bin/Xvnc 2>/dev/null | grep -qi kasm; then
  echo "kasmvnc ready"
else
  echo "KASM-INSTALL-FAIL"
  which Xvnc || ls -la /usr/bin/Xvnc 2>/dev/null
fi

echo "== pulse (rootless, /tmp/psock) =="
sudo mkdir -p /etc/pulse
sudo tee /etc/pulse/gamestream.pa >/dev/null << 'PEOF'
load-module module-native-protocol-unix auth-anonymous=1 socket=/tmp/psock
load-module module-always-sink
load-module module-rescue-streams
PEOF
pkill -9 -f pulseaudio 2>/dev/null || true
sleep 1
rm -f /tmp/psock
setsid nohup pulseaudio -D -nF /etc/pulse/gamestream.pa --exit-idle-time=-1 --disable-shm >/tmp/pulse.log 2>&1 &
sleep 6
export PULSE_SERVER=unix:/tmp/psock
pactl load-module module-null-sink sink_name=gamestream >/dev/null 2>&1 || true
pactl list short sinks

echo "== noVNC =="
wget -q -O /tmp/novnc.tgz https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz
mkdir -p /opt/noVNC && tar -xzf /tmp/novnc.tgz -C /opt/noVNC --strip-components=1 && rm /tmp/novnc.tgz

echo "== ws libs =="
mkdir -p /opt/wstcp /opt/relay
cd /opt/wstcp && npm install ws --silent >/dev/null 2>&1
cp -r /opt/wstcp/node_modules /opt/relay/node_modules

echo "== guacamole (guacd build + guacamole-lite) =="
# сборка guacd из исходников в фоне (guacd в apt нет, только libguac-dev)
if [ ! -x /usr/local/sbin/guacd ]; then
  echo "building guacd in background..."
  setsid nohup bash -c '
    exec > /tmp/guacd_build.log 2>&1
    set -e
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get install -y -qq build-essential autoconf automake libtool pkg-config \
      libcairo2-dev libpng-dev libjpeg-turbo8-dev libvncserver-dev libssl-dev \
      libossp-uuid-dev libpango1.0-dev libwebsockets-dev >/dev/null 2>&1
    cd /tmp
    rm -rf guacamole-server
    git clone --depth 1 --branch 1.5.5 https://github.com/apache/guacamole-server.git
    cd guacamole-server
    autoreconf -fi
    ./configure --disable-static --with-init-dir=no
    make -j2
    sudo make install
    sudo ldconfig
    echo GUACD-BUILD-DONE
  ' >/dev/null 2>&1 &
fi
# ждём guacd недолго (сборка идёт в фоне; для jackbox guac опционален)
for w in $(seq 1 24); do
  [ -x /usr/local/sbin/guacd ] && grep -q GUACD-BUILD-DONE /tmp/guacd_build.log 2>/dev/null && break
  sleep 5
done
if [ -x /usr/local/sbin/guacd ]; then
  echo "guacd ready: $(/usr/local/sbin/guacd --version 2>/dev/null | head -3 | tr '\n' ' ')"
else
  echo "WARN guacd still building/absent (не блокирует старт стека)"
fi
mkdir -p /opt/guac
cd /opt/guac && npm install --silent guacamole-lite@1.2.0 >/dev/null 2>&1
cd /opt/guac && npm install --silent guacamole-common-js@1.5.0 >/dev/null 2>&1
if [ -f node_modules/guacamole-common-js/dist/cjs/guacamole-common.js ]; then
  cp node_modules/guacamole-common-js/dist/cjs/guacamole-common.js /opt/guac/guacjs.js
fi

echo "== guacamole run.js (tunnel) =="
cat > /opt/guac/run.js << 'GUACEOR'
const http=require('http'),fs=require('fs'),path=require('path');
const GuacamoleLite=require('guacamole-lite');
const PORT=Number(process.env.PORT||6941);
const RFB=Number(process.env.RFB||5918);
const ROOT='/opt/guac';
const CLOG='/tmp/clog.log';
function clog(m){try{fs.appendFileSync(CLOG,new Date().toISOString()+' '+m+'\n');}catch(_){}}
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.json':'application/json','.woff2':'font/woff2'};
let cur={};
const httpServer=http.createServer((req,res)=>{
  const u=(req.url||'/').split('?')[0];
  if(u==='/clog'&&req.method==='POST'){let b='';req.on('data',d=>b+=d);req.on('end',()=>{clog('GUACCL '+String(b).slice(0,500));res.writeHead(200,{'Content-Type':'text/plain'});res.end('ok');});return;}
  if(u==='/clog'){res.writeHead(200,{'Content-Type':'text/plain'});res.end(JSON.stringify(cur)||'{}');return;}
  let f;
  if(u==='/')f=path.join(ROOT,'guac.html');
  else f=path.normalize(path.join(ROOT,u));
  if(!f.startsWith(ROOT)){res.writeHead(403);res.end();return;}
  fs.readFile(f,(e,d)=>{if(e){res.writeHead(404);res.end('nf');return;}
    res.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});res.end(d);});
});
const guacdOptions={host:'127.0.0.1',port:4822};
const clientOptions={
  crypt:{cypher:'AES-256-CBC',key:'MySuperSecretKeyForParamsToken12'},
  log:{level:1,stdLog:(m)=>{cur.l=m.split('\n')[0];clog('GUAC '+String(m).slice(0,300));},errorLog:(m)=>clog('GUAC-ERR '+String(m).slice(0,300))},
  allowReconnect:true,
  maxInactivityTime:0,
  connectionDefaultSettings:{vnc:{port:'5918',width:1280,height:720,dpi:96}}
};
const callbacks={processConnectionSettings:(s,cb)=>{cur.s=JSON.stringify(s).slice(0,200);clog('SESS '+cur.s);cb(undefined,s);}};
try{
  new GuacamoleLite({server:httpServer},guacdOptions,clientOptions,callbacks);
  clog('guac tunnel init on '+PORT);
}catch(e){clog('GUAC INIT FAIL '+e.message);}
httpServer.listen(PORT,()=>{clog('guac tunnel http on '+PORT);cur.up=true;console.log('guac on '+PORT);});
GUACEOR

echo "== guacamole client page =="
cat > /opt/guac/guac.html << 'GUACHTMLE'
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>guacamole</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden;touch-action:none;font-family:system-ui,sans-serif}
#host{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;background:#000}
#st{position:fixed;top:calc(8px + env(safe-area-inset-top));left:calc(8px + env(safe-area-inset-left));z-index:9;color:#94a3b8;font:12px monospace;background:rgba(0,0,0,.55);padding:6px 9px;border-radius:8px;max-width:78vw;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#kb{position:fixed;left:0;right:0;bottom:0;z-index:8;display:none;flex-wrap:wrap;justify-content:center;gap:6px;padding:8px calc(6px + env(safe-area-inset-right)) calc(8px + env(safe-area-inset-bottom)) calc(6px + env(safe-area-inset-left));background:rgba(10,14,20,.86);backdrop-filter:blur(4px);border-top:1px solid rgba(255,255,255,.14)}
#kb button{min-width:44px;min-height:40px;padding:4px 10px;background:#1f2a37;border:1px solid rgba(255,255,255,.16);color:#e5e7eb;border-radius:7px;font-size:16px}
#kb button.w{background:#3b82f6}
#kb button:active{transform:scale(.93);background:#2a6bd6}
body.kb #kb{display:flex}
body.kb #host{bottom:46%}
#hide{position:fixed;right:calc(10px + env(safe-area-inset-right));top:calc(10px + env(safe-area-inset-top));z-index:10;background:rgba(11,15,20,.6);color:#e5e7eb;border:1px solid rgba(255,255,255,.25);padding:8px 11px;border-radius:8px;font-size:13px;cursor:pointer;backdrop-filter:blur(3px)}
</style></head><body>
<div id="host"></div>
<div id="st">connect…</div>
<button id="hide">⌨</button>
<div id="kb"></div>
<script>
window.module={exports:{}};
var module=window.module,exports=module.exports;
</script>
<script src="/guacjs.js"></script>
<script>
var Guacamole=window.module.exports;
var KEY='MySuperSecretKeyForParamsToken12';
var st=document.getElementById('st');
function log(m){st.textContent=m;}
function b64(u8){var s='';for(var i=0;i<u8.length;i++)s+=String.fromCharCode(u8[i]);return btoa(s);}
async function makeToken(){
  var payload={connection:{type:'vnc',settings:{hostname:'127.0.0.1',port:String(RFB)}}};
  var enc=new TextEncoder(),iv=crypto.getRandomValues(new Uint8Array(16));
  var key=await crypto.subtle.importKey('raw',enc.encode(KEY),{name:'AES-CBC'},false,['encrypt']);
  var ct=await crypto.subtle.encrypt({name:'AES-CBC',iv:iv},key,enc.encode(JSON.stringify(payload)));
  var data={iv:b64(iv),value:b64(new Uint8Array(ct))};
  return b64(enc.encode(JSON.stringify(data)));
}
var RFB=parseInt((location.search.match(/[?&]rfb=(\d+)/)||[])[1]||'5918',10);
var host=document.getElementById('host');
var client=null,tunnel=null,keyboard=null;
async function connect(){
  log('making token…');
  var token=await makeToken();
  tunnel=new Guacamole.WebSocketTunnel('/tunnel');
  client=new Guacamole.Client(tunnel);
  client.onerror=function(s){log('ERR '+s.code+' '+s.message);fetch('/clog',{method:'POST',body:'guac err '+(s.code||'')+' '+(s.message||'')});};
  client.onstatechange=function(s){log('state '+s);fetch('/clog',{method:'POST',body:'guac state '+s});};
  client.onname=function(n){log(n);};
var display=client.getDisplay();
  var el=display.getElement();
  host.appendChild(el);
  var pressed=false;
  function cd(pointer){
    var r=el.getBoundingClientRect();
    var dw=display.getWidth()||1280,dh=display.getHeight()||720;
    return {x:Math.round((pointer.clientX-r.left)/r.width*dw),y:Math.round((pointer.clientY-r.top)/r.height*dh)};
  }
  function sendMouse(x,y,left){
    try{client.sendMouseState(new Guacamole.Mouse.State(x,y,left,false,false,false,false));}catch(e){}
  }
  el.style.touchAction='none';
  el.addEventListener('pointerdown',function(e){e.preventDefault();pressed=true;try{el.setPointerCapture(e.pointerId);}catch(_){}var p=cd(e);sendMouse(p.x,p.y,true);log('pdn '+p.x+' '+p.y);});
  el.addEventListener('pointermove',function(e){var p=cd(e);sendMouse(p.x,p.y,pressed);});
  el.addEventListener('pointerup',function(e){e.preventDefault();pressed=false;var p=cd(e);sendMouse(p.x,p.y,false);});
  el.addEventListener('pointercancel',function(){pressed=false;});
  keyboard=new Guacamole.Keyboard(document);
  keyboard.onkeydown=function(keysym){client.sendKeyEvent(1,keysym);if(delayedReset)clearTimeout(delayedReset),delayedReset=setTimeout(function(){keyboard.reset();},100);};
  keyboard.onkeyup=function(keysym){client.sendKeyEvent(0,keysym);};
  var delayedReset=null;
  function fit(){
    var w=host.clientWidth,h=host.clientHeight;
    var dw=display.getWidth(),dh=display.getHeight();
    if(!dw||!dh||!w||!h)return;
    try{display.scale(Math.min(w/dw,h/dh));}catch(e){}
  }
  window.addEventListener('resize',fit);
  setInterval(fit,600);
  log('connect…');
  client.connect('token='+encodeURIComponent(token));
}
function key(name){var ev=new KeyboardEvent('keydown',{key:name,bubbles:true,cancelable:true});document.dispatchEvent(ev);setTimeout(function(){var ev2=new KeyboardEvent('keyup',{key:name,bubbles:true,cancelable:true});document.dispatchEvent(ev2);},60);}
function buildKB(){
  var kb=document.getElementById('kb');
  var rows=['1234567890','qwertyuiop','asdfghjkl','zxcvbnm@.'];
  rows.forEach(function(r){var d=document.createElement('div');d.style.cssText='display:flex;gap:6px;justify-content:center;width:100%';
    Array.from(r).forEach(function(c){var b=document.createElement('button');b.textContent=c;b.onmousedown=function(e){e.preventDefault();key(c);};d.appendChild(b);});kb.appendChild(d);});
  var row2=document.createElement('div');row2.style.cssText='display:flex;gap:6px;justify-content:center;width:100%';
  var sp=document.createElement('button');sp.style.cssText='min-width:120px';sp.textContent='spc';sp.onmousedown=function(e){e.preventDefault();key(' ');};
  var en=document.createElement('button');en.className='w';en.textContent='⏎';en.onmousedown=function(e){e.preventDefault();key('Enter');};
  var bs=document.createElement('button');bs.className='w';bs.textContent='⌫';bs.onmousedown=function(e){e.preventDefault();key('Backspace');};
  row2.appendChild(sp);row2.appendChild(en);row2.appendChild(bs);kb.appendChild(row2);
}
document.getElementById('hide').onclick=function(){document.body.classList.toggle('kb');};
buildKB();
connect();
</script></body></html>
GUACHTMLE

echo "GUACD-BOOTSTRAP-DONE"

echo "== wstcp proxy =="
cat > /opt/wstcp/proxy.js << 'JEOF'
const http=require('http'),fs=require('fs'),path=require('path'),net=require('net');
const WebSocket=require('ws');
const PORT=Number(process.env.PORT||6901);
const WEB=process.env.WEB||'/opt/noVNC';
const RFB=Number(process.env.RFB||5917);
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.wasm':'application/wasm','.map':'application/json'};
const server=http.createServer((req,res)=>{
  let u=(req.url||'/').split('?')[0];
  if(u==='/')u='/vnc.html';
  const f=path.normalize(path.join(WEB,u));
  if(!f.startsWith(WEB)){res.writeHead(403);res.end();return;}
  fs.readFile(f,(e,d)=>{if(e){res.writeHead(404);res.end('nf');return;}
    res.writeHead(200,{'Content-Type':MIME[path.extname(f)]||'application/octet-stream'});res.end(d);});
});
const wss=new WebSocket.Server({noServer:true});
server.on('upgrade',(req,socket,head)=>{
  socket.on('error',()=>{});
  wss.handleUpgrade(req,socket,head,(ws)=>{
    const sock=net.connect(RFB,'127.0.0.1');
    sock.on('data',d=>{if(ws.readyState===1)ws.send(d);});
    sock.on('error',()=>{try{ws.terminate();}catch(_){} });
    ws.on('close',()=>sock.destroy());
    ws.on('error',()=>{});
    sock.on('close',()=>{try{ws.terminate();}catch(_){} });
    ws.on('message',d=>{if(sock.writable&&!sock.destroyed)sock.write(d);});
  });
});
server.on('error',e=>console.log('srv err',e.message));
server.listen(PORT,()=>console.log('wstcp on '+PORT+' -> rfb '+RFB));
JEOF

echo "== audio relay =="
cat > /opt/relay/server.js << 'RELAYEOF'
const http=require('http'),WebSocket=require('ws');
const {spawn}=require('child_process');
const PORT=Number(process.env.PORT||6902);
const VNC=process.env.VNC_URL||'';
const PAGE=`<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>game-stream</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden;touch-action:none}
#stage{position:fixed;inset:0}
iframe{width:100%;height:100%;border:0;display:block;background:#000}
#ctl{position:fixed;left:calc(10px + env(safe-area-inset-left));bottom:calc(10px + env(safe-area-inset-bottom));z-index:99;display:flex;gap:8px;align-items:center;flex-wrap:wrap;transition:opacity .2s}
button{background:#3b82f6;color:#fff;border:0;padding:11px 16px;border-radius:8px;font-size:14px;cursor:pointer}
button:active{transform:scale(.96)}
#st{color:#9ca3af;margin-left:4px;font:12px monospace;line-height:38px}
#hide{position:fixed;right:calc(10px + env(safe-area-inset-right));top:calc(10px + env(safe-area-inset-top));z-index:100;
background:rgba(11,15,20,.55);color:#e5e7eb;border:1px solid rgba(255,255,255,.25);padding:7px 10px;border-radius:8px;font-size:12px;cursor:pointer;backdrop-filter:blur(3px)}
#hide:hover{background:rgba(11,15,20,.8)}
body.hid #ctl{opacity:0;pointer-events:none}
body.hid:hover #ctl{opacity:1;pointer-events:auto}
@media (orientation:landscape) and (max-height:560px){
  button{padding:6px 9px;font-size:11px;border-radius:6px}
  #st{font-size:10px;line-height:30px}
  #hide{padding:4px 7px;font-size:11px}
}</style></head><body>
<div id="stage"><iframe id="g"></iframe></div>
<button id="hide">⋯</button>
<div id="ctl"><button id="f">Fullscreen</button><button id="s">Play sound</button><span id="st"></span></div>
<script>
var D=parseInt((location.search.match(/[?&]d=(\\d+)/)||[])[1]||"300",10);if(D<250)D=250;if(D>5000)D=5000;
var CAP=44100*90,ring=new Int16Array(CAP),tail=0,head=0,cnt=0,gate=false,ctx,ws,wsc=false,playing=false,started=false;
var START=Math.floor(D/1000*44100),HOLD=Math.floor(START/3);
function vncUrl(){
  var base=VNC||"";
  if(base){
    if(base.indexOf('?')>=0)return base+'&autoconnect=true&resize=scale&reconnect=1&show_dot=true';
    return base+'?autoconnect=true&resize=scale&reconnect=1&show_dot=true';
  }
  var h=location.host;
  if(/-?\\d+\\.app\\.github\\.dev$/.test(h)){
    return "https://"+h.replace(/-\\d+\\.app\\.github\\.dev$/,"-6901.app.github.dev")+"?autoconnect=true&resize=scale&reconnect=1&show_dot=true";
  }
  return location.protocol+"//"+location.host.replace(/:(\\d+)/,":6901")+"?autoconnect=true&resize=scale&reconnect=1&show_dot=true";
}
document.getElementById('g').src=vncUrl();
function wr(b){var n=b.length,w=(tail+n)%CAP;if(w>tail){ring.set(b,tail);}else{var p=CAP-tail;ring.set(b.subarray(0,p),tail);ring.set(b.subarray(p),0);}tail=w;cnt+=n;if(cnt>CAP)cnt=CAP;}
function push(u8){wr(new Int16Array(u8.buffer,u8.byteOffset,u8.length>>1));}
function link(){if(ws&&wsc)return;var proto=location.protocol==="https:"?"wss://":"ws://";ws=new WebSocket(proto+location.host);ws.binaryType="arraybuffer";ws.onopen=function(){wsc=true;};ws.onmessage=function(ev){push(new Uint8Array(ev.data));};ws.onclose=function(){wsc=false;setTimeout(link,1500);};ws.onerror=function(){};}
function zero(o){var n=o.length,l=o.getChannelData(0),r=o.getChannelData(1);for(var i=0;i<n;i++){l[i]=0;r[i]=0;}}
function start(){if(playing)return;playing=true;ctx=new(window.AudioContext||window.webkitAudioContext)({sampleRate:44100,latencyHint:"interactive"});
var proc=ctx.createScriptProcessor(4096,0,2);
proc.onaudioprocess=function(e){var o=e.outputBuffer,n=o.length,cur=cnt>>1;
if(gate){if(cur<HOLD){gate=false;document.getElementById("st").textContent="buffering…";zero(o);return;}}else{if(cur>=START){gate=true;document.getElementById("st").textContent="sound on (delay "+D+"ms)";}else{zero(o);return;}}
var l=o.getChannelData(0),r=o.getChannelData(1),need=n*2,h=head,take=Math.min(need,cnt);
var end=h+take,k=0;
if(end<=CAP){for(var i=h;i<end;i+=2){l[k]=ring[i]/32768;r[k]=ring[i+1]/32768;k++;}}
else{for(var j=h;j<CAP;j+=2){l[k]=ring[j]/32768;r[k]=ring[j+1]/32768;k++;}for(var j2=0;j2<end-CAP;j2+=2){l[k]=ring[j2]/32768;r[k]=ring[j2+1]/32768;k++;}}
while(k<n){l[k]=0;r[k]=0;k++;}
head=(head+take)%CAP;cnt-=take;};
proc.connect(ctx.destination);ctx.resume();link();document.getElementById("st").textContent="sound on";}
document.getElementById("s").onclick=start;
function goFS(){
  var g=document.getElementById("g");
  try{
    if(window.top!==window.self){window.parent.postMessage('@fs','*');return;}
    var req=g.requestFullscreen||g.webkitRequestFullscreen;
    if(req)req.call(g);
    try{if(screen.orientation&&screen.orientation.lock)screen.orientation.lock('landscape').catch(function(){});}catch(e){}
  }catch(e){}
}
document.getElementById("f").onclick=goFS;
document.getElementById("hide").onclick=function(){document.body.classList.toggle('hid');};
</script></body></html>`;
const server=http.createServer((q,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(PAGE);});
const wss=new WebSocket.Server({server});
const env=Object.assign({},process.env,{PULSE_SERVER:process.env.PSO||'unix:/tmp/psock'});
function pspawn(){
  const p=spawn('parec',['--device=gamestream.monitor','--format=s16le','--channels=2','--rate=44100'],{env});
  p.stdout.on('data',d=>{for(const w of wss.clients)if(w.readyState===1)w.send(d);});
  p.stderr.on('data',d=>{});
  p.on('error',()=>{});
  p.on('exit',()=>{setTimeout(pspawn,3000);});
}
server.on('error',e=>console.log('srv err',e.message));
server.listen(PORT,()=>{console.log('relay on '+PORT+' vnc='+(VNC||'auto'));pspawn();});
RELAYEOF
echo "== Xvnc + wstcp =="
pkill -9 Xvnc 2>/dev/null || true
sleep 2
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
setsid nohup Xvnc :99 -geometry 640x480 -depth 24 -rfbport 5917 -noWebsocket -SecurityTypes None -alwaysshared >/tmp/xvnc.log 2>&1 &
sleep 8
setsid nohup env PORT=6901 RFB=5917 node /opt/wstcp/proxy.js >/tmp/wstcp.log 2>&1 &

echo "== openbox =="
pgrep -x openbox >/dev/null || { DISPLAY=:99 setsid nohup openbox >/dev/null 2>&1 & sleep 3; }

echo "== DDNet =="
if [ ! -x $H/ddnet/DDNet ]; then
  wget -q -O /tmp/dd.tar.xz https://ddnet.org/downloads/DDNet-nightly-linux_x86_64.tar.xz
  tar -xJf /tmp/dd.tar.xz -C /tmp
  S=$(ls -d /tmp/DDNet-* | head -1)
  rm -rf $H/ddnet && mkdir -p $H/ddnet
  cp -r "$S/data" $H/ddnet/ && cp "$S/DDNet" $H/ddnet/DDNet && chmod +x $H/ddnet/DDNet
  rm /tmp/dd.tar.xz
fi
mkdir -p $H/.local/share/ddnet
cat > $H/.local/share/ddnet/settings_ddnet.cfg << 'CFG'
gfx_vsync 0
gfx_high_detail 0
gfx_texture_quality 0
gfx_quad_quality 0
gfx_fs_blur 0
gfx_water_reflections 0
gfx_shaders 0
gfx_fullscreen 0
snd_enable 1
gfx_screen_width 640
gfx_screen_height 480
connect uber.ddnet.fr
CFG
pkill -9 -f 'ddnet/DDNet' 2>/dev/null || true
sleep 2
setsid nohup env DISPLAY=:99 SDL_AUDIODRIVER=pulse SDL_VIDEODRIVER=x11 PULSE_SERVER=unix:/tmp/psock LIBGL_ALWAYS_SOFTWARE=1 $H/ddnet/DDNet >/tmp/dd.log 2>&1 &

echo "== ddmap watchdog =="
cat > /opt/ddmap.sh << 'MEOF'
#!/bin/bash
export DISPLAY=:99
while true; do
  W=$(xdotool search --name 'DDNet Client' 2>/dev/null | head -1)
  if [ -n "$W" ]; then
    st=$(xwininfo -id "$W" 2>/dev/null | grep 'Map State' | awk '{print $3}')
    if [ "$st" = "IsUnMapped" ]; then
      xdotool windowmap --sync "$W" 2>/dev/null
      xdotool windowactivate --sync "$W" 2>/dev/null
      xdotool windowraise "$W" 2>/dev/null
      sleep 3
    fi
  fi
  sleep 5
done
MEOF
chmod +x /opt/ddmap.sh
pgrep -f ddmap.sh >/dev/null || { setsid nohup /opt/ddmap.sh >/dev/null 2>&1 & echo "ddmap started"; }

echo "== relay start =="
pkill -9 -f '/opt/relay/server.js' 2>/dev/null || true
sleep 1
setsid nohup env PORT=6902 node /opt/relay/server.js >/tmp/audio.log 2>&1 &

sleep 15
echo "DSTACK-STATE:"
ss -tln | grep -oE ':(5917|6901|6902) ' | sort -u | tr '\n' ' '; echo
pgrep -c -f 'ddnet/DDNet' | xargs -I{} echo "ddnet procs: {}"
pgrep -x openbox >/dev/null && echo "openbox: UP" || echo "openbox: DOWN"
grep -aE 'GPU renderer|Created' /tmp/dd.log 2>/dev/null | tail -2
DISPLAY=:99 xdotool search --onlyvisible --name DDNet 2>/dev/null | head -1 | xargs -I{} echo "ddnet window: {}"
echo "STACK-UP-END"