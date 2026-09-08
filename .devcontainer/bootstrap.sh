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

echo "== kasmvnc (Xvnc) =="
wget -q -O /tmp/kasmvnc.deb https://github.com/kasmtech/KasmVNC/releases/download/v1.5.0/kasmvncserver_jammy_1.5.0_amd64.deb
sudo apt-get install -y -qq /tmp/kasmvnc.deb >/tmp/aptkasm.log 2>&1 || { echo "kasm install FAILED"; tail -5 /tmp/aptkasm.log; }
command -v Xvnc || echo "WARN Xvnc missing"

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