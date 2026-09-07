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
cat > /opt/relay/server.js << 'JEOF'
const http=require('http'),WebSocket=require('ws');
const {spawn}=require('child_process');
const PORT=Number(process.env.PORT||6902);
const VNC=process.env.VNC_URL||'';
const PAGE='<!doctype html><html><head><meta charset="utf-8"><title>DDNet Remote</title>'+
'<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#stage{position:fixed;inset:0}'+
'iframe{width:100%;height:100%;border:0}#ctl{position:fixed;left:10px;bottom:10px;z-index:99;display:flex;gap:8px;align-items:center}'+
'button{background:#3b82f6;color:#fff;border:0;padding:10px 16px;border-radius:6px;font-size:14px;cursor:pointer}'+
'#st{color:#9ca3af;margin-left:4px;font:12px monospace;line-height:38px}</style></head><body>'+
'<div id="stage"><iframe id="g" src="@@SRC@@"></iframe></div>'+
'<div id="ctl"><button id="s">Play sound</button><span id="st"></span><button id="f">Fullscreen</button></div>'+
'<script>var ws,ctx,playing=false,buf=new Int16Array(0);'+
'function push(u8){var s16=new Int16Array(u8.buffer,u8.byteOffset,u8.length>>1);var t=new Int16Array(buf.length+s16.length);t.set(buf);t.set(s16,buf.length);buf=t;}'+
'function link(){var proto=location.protocol==="https:"?"wss://":"ws://";ws=new WebSocket(proto+location.host);ws.binaryType="arraybuffer";'+
'ws.onmessage=function(ev){push(new Uint8Array(ev.data));};ws.onclose=function(){setTimeout(link,2000);};}'+
'function startSound(){if(playing)return;ctx=new(window.AudioContext||window.webkitAudioContext)({sampleRate:44100});'+
'var proc=ctx.createScriptProcessor(4096,0,2);'+
'proc.onaudioprocess=function(e){var o=e.outputBuffer,l=o.getChannelData(0),r=o.getChannelData(1);'+
'var n=o.length*2,m=Math.min(buf.length,n);for(var j=0,i=0;i+1<m;i+=2,j++){l[j]=buf[i]/32768;r[j]=buf[i+1]/32768;}'+
'if(m<n){l.fill(0,m>>1);r.fill(0,m>>1);}buf=buf.subarray(m);};'+
'link();proc.connect(ctx.destination);ctx.resume();playing=true;document.getElementById("st").textContent="sound on";}'+
'document.getElementById("s").onclick=startSound;'+
'document.getElementById("f").onclick=function(){var g=document.getElementById("g");'+
'if(document.fullscreenElement||document.webkitFullscreenElement){document.exitFullscreen&&document.exitFullscreen();document.webkitExitFullscreen&&document.webkitExitFullscreen();}'+
'else{g.requestFullscreen?g.requestFullscreen():g.webkitRequestFullscreen&&g.webkitRequestFullscreen();}};'+
'</script></body></html>';
const env=Object.assign({},process.env,{PULSE_SERVER:'unix:/tmp/psock'});
function derive(host){
  if(!host)return '';
  if(/-?\d+\.app\.github\.dev$/.test(host))
    return 'https://'+host.replace(/-\d+\.app\.github\.dev$/,'-6901.app.github.dev')+'/?autoconnect=true&resize=scale';
  return '';
}
const server=http.createServer((q,res)=>{
  res.setHeader('Content-Type','text/html; charset=utf-8');
  let src=VNC?VNC+'/?autoconnect=true&resize=scale':derive(q.headers.host||'');
  res.end(PAGE.replace('@@SRC@@',src.replace(/\&/g,'&amp;')));
});
const wss=new WebSocket.Server({server});
function pspawn(){
  const p=spawn('parec',['--device=gamestream.monitor','--format=s16le','--channels=2','--rate=44100'],{env});
  p.stdout.on('data',d=>{for(const w of wss.clients)if(w.readyState===1)w.send(d);});
  p.stderr.on('data',d=>console.log('parec:',d.toString().trim()));
  p.on('error',e=>console.log('parec err',e.message));
  p.on('exit',c=>{console.log('parec exited',c,'-> respawn');setTimeout(pspawn,3000);});
}
server.on('error',e=>console.log('srv err',e.message));
server.listen(PORT,()=>{console.log('relay on '+PORT+' vnc='+(VNC||'auto'));pspawn();});
JEOF

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
snd_enable 1
gfx_screen_width 640
gfx_screen_height 480
connect uber.ddnet.fr
CFG
pkill -9 -f 'ddnet/DDNet' 2>/dev/null || true
sleep 2
setsid nohup env DISPLAY=:99 SDL_AUDIODRIVER=pulse SDL_VIDEODRIVER=x11 PULSE_SERVER=unix:/tmp/psock LIBGL_ALWAYS_SOFTWARE=1 $H/ddnet/DDNet >/tmp/dd.log 2>&1 &

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