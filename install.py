import subprocess as sp, time, os, socket, re, glob

def R(c, t=400):
    try:
        r = sp.run(c, shell=True, capture_output=True, text=True, timeout=t)
        return (r.stdout or '') + (r.stderr or '')
    except Exception as e:
        return str(e)

V_PORT, A_PORT = 6901, 6902
os.environ['PULSE_SERVER'] = 'unix:/run/pulse/native'

def STEP(name, fn):
    try:
        print('=== ' + name + ' ===')
        fn()
    except Exception as e:
        print('ERR:', e)

# ---------- 1. Установки (пропускаются, если стоят) ----------
def installs():
    miss = [b for b in ['xdotool', 'openbox', 'parec', 'pactl', 'xauth'] if not R('command -v ' + b)]
    if miss:
        R('apt-get update -qq 2>&1 | tail -1')
        print(R('DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xdotool openbox pulseaudio pulseaudio-utils x11-utils xauth imagemagick 2>&1 | tail -1'))
    if not os.path.exists('/usr/bin/Xvnc'):
        rel = R('curl -fsSL https://api.github.com/repos/kasmtech/KasmVNC/releases/latest', t=60)
        u = re.search(r'"browser_download_url":\s*"([^"]*kasmvncserver[^"]*amd64\.deb)"', rel)
        if u:
            R('wget -q -O /tmp/kasm.deb "' + u.group(1) + '"')
            R('dpkg --force-all -i /tmp/kasm.deb 2>&1 | tail -1')
            R('apt-get -fy install -qq 2>&1 | tail -1')
    R('groupadd -f ssl-cert 2>/dev/null; usermod -aG ssl-cert root 2>/dev/null')
    if not os.path.exists('/usr/local/bin/frpc'):
        R('wget -q -O /tmp/frpc.tgz https://github.com/fatedier/frp/releases/download/v0.71.0/frp_0.71.0_linux_amd64.tar.gz')
        R('tar -xzf /tmp/frpc.tgz -C /tmp && cp /tmp/frp_*/frpc /usr/local/bin/frpc && chmod +x /usr/local/bin/frpc')
    if not os.path.exists('/content/ddnet/DDNet'):
        R('wget -q -O /tmp/dd.tar.xz https://ddnet.org/downloads/DDNet-nightly-linux_x86_64.tar.xz')
        R('tar -xJf /tmp/dd.tar.xz -C /tmp')
        d = glob.glob('/tmp/DDNet-*')
        if d:
            s = d[0]
            R('mkdir -p /content/ddnet && cp -r ' + s + '/data /content/ddnet/ && cp ' + s + '/DDNet /content/ddnet/DDNet 2>/dev/null')
            R('chmod +x /content/ddnet/DDNet')
    print('Xvnc:', R('command -v Xvnc').strip() or 'MISSING')
    print('frpc:', R('/usr/local/bin/frpc -v 2>&1', t=10).strip() or 'MISSING')
    print('DDNet:', R('test -x /content/ddnet/DDNet && echo ok || echo MISSING').strip())

STEP('1. Установки', installs)

# ---------- 2. Конфиги ----------
def confs():
    os.makedirs('/root/.vnc', exist_ok=True)
    os.makedirs('/root/.local/share/ddnet', exist_ok=True)
    os.makedirs('/etc/pulse', exist_ok=True)
    open('/root/.local/share/ddnet/settings_ddnet.cfg', 'w').write('''gfx_vsync 0
gfx_high_detail 0
gfx_texture_quality 0
gfx_quad_quality 0
gfx_fs_blur 0
gfx_water_reflections 0
gfx_shaders 0
snd_enable 1
''')
    yaml = '''
desktop:
  resolution:
    width: 640
    height: 480
  allow_resize: false
  pixel_depth: 24
network:
  protocol: http
  interface: 0.0.0.0
  websocket_port: @@VPORT@@
  use_ipv4: true
  use_ipv6: false
  ssl:
    require_ssl: false
encoding:
  max_frame_rate: 20
  rect_encoding_mode:
    min_quality: 4
    max_quality: 6
    rectangle_compress_threads: auto
  compare_framebuffer: auto
server:
  advanced:
    kasm_password_file: ${HOME}/.kasmpasswd
  auto_shutdown:
    no_user_session_timeout: never
pointer:
  enabled: true
keyboard:
  raw_keyboard: false
command_line:
  prompt: false
'''.replace('@@VPORT@@', str(V_PORT))
    open('/root/.vnc/kasmvnc.yaml', 'w').write(yaml)
    open('/root/.vnc/xstartup', 'w').write('#!/bin/sh\nopenbox &\n')
    R('chmod +x /root/.vnc/xstartup')
    if 'auth-anonymous' not in R('cat /etc/pulse/system.pa 2>/dev/null'):
        open('/etc/pulse/system.pa', 'w').write('''#!/usr/bin/pulseaudio -nF
load-module module-native-protocol-unix auth-anonymous=1
load-module module-detect
''')
    if not os.path.exists('/root/.kasmpasswd'):
        R("printf 'testpass\\ntestpass\\n' | vncpasswd -u root -w -r 2>&1 | tail -1")
    print('configs ok, V=' + str(V_PORT) + ' A=' + str(A_PORT))

STEP('2. Конфиги', confs)

# ---------- 3. page.html + server.js ----------
def relay_files():
    os.makedirs('/content/audio-relay', exist_ok=True)
    if not os.path.isdir('/content/audio-relay/node_modules/ws'):
        R('cd /content/audio-relay && npm install ws --silent 2>&1 | tail -1', t=200)
    page = r'''
<!doctype html><html><head><meta charset="utf-8"><title>DDNet Remote</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden}
#stage{position:fixed;inset:0}
iframe{width:100%;height:100%;border:0}
#ctl{position:fixed;left:10px;bottom:10px;z-index:99;display:flex;gap:8px}
button{background:#3b82f6;color:#fff;border:0;padding:10px 16px;border-radius:6px;font-size:14px;cursor:pointer}
#st{color:#9ca3af;margin-left:4px;font:12px monospace;line-height:38px}
</style></head>
<body>
<div id="stage"><iframe id="g" src="http://vds2.fenst4r.live:@@VPORT@@/?autoconnect=true&resize=scale"></iframe></div>
<div id="ctl">
  <button id="s">Включить звук</button><span id="st"></span>
  <button id="f">&#11036; Во весь экран</button>
</div>
<script>
var ws, ctx, playing = false, buf = new Int16Array(0);
function push(u8){ var s16=new Int16Array(u8.buffer,u8.byteOffset,u8.length>>1); var t=new Int16Array(buf.length+s16.length); t.set(buf); t.set(s16,buf.length); buf=t; }
function link(){ ws=new WebSocket('ws://'+location.host); ws.binaryType='arraybuffer';
  ws.onmessage=function(ev){ push(new Uint8Array(ev.data)); };
  ws.onclose=function(){ setTimeout(link,2000); }; }
function start(){ if(playing) return;
  ctx=new (window.AudioContext||window.webkitAudioContext)({sampleRate:44100});
  var proc=ctx.createScriptProcessor(4096,0,2);
  proc.onaudioprocess=function(e){ var o=e.outputBuffer,l=o.getChannelData(0),r=o.getChannelData(1);
    var n=o.length*2,m=Math.min(buf.length,n);
    for(var j=0,i=0;i+1<m;i+=2,j++){l[j]=buf[i]/32768;r[j]=buf[i+1]/32768;}
    if(m<n){l.fill(0,m>>1);r.fill(0,m>>1);}
    buf=buf.subarray(m); };
  link(); proc.connect(ctx.destination); ctx.resume(); playing=true;
  document.getElementById('st').textContent='звук вкл'; }
document.getElementById('s').onclick=start;
document.getElementById('f').onclick=function(){ var g=document.getElementById('g');
  if(!document.fullscreenElement){ if(g.requestFullscreen){g.requestFullscreen();} else if(g.webkitRequestFullscreen){g.webkitRequestFullscreen();} }
  else { if(document.exitFullscreen){document.exitFullscreen();} else if(document.webkitExitFullscreen){document.webkitExitFullscreen();} } };
</script></body></html>
'''.replace('@@VPORT@@', str(V_PORT))
    open('/content/audio-relay/page.html', 'w').write(page)
    srv = r'''
const http = require('http');
const fs = require('fs');
const WebSocket = require('ws');
const { spawn } = require('child_process');
const PORT = @@APORT@@;
const PAGE = fs.readFileSync('/content/audio-relay/page.html', 'utf8');
const players = new Set();
const server = http.createServer((q, res) => { res.setHeader('Content-Type', 'text/html; charset=utf-8'); res.end(PAGE); });
const wss = new WebSocket.Server({ server });
const paenv = Object.assign({}, process.env, { PULSE_SERVER: 'unix:/run/pulse/native' });
const parec = spawn('parec', ['--device=gamestream.monitor', '--format=s16le', '--channels=2', '--rate=44100'], { env: paenv });
parec.on('error', e => { console.log('parec spawn err:', e.message); setTimeout(() => process.exit(1), 1000); });
parec.stdout.on('data', d => { for (const w of players) if (w.readyState === 1) w.send(d); });
parec.stderr.on('data', d => console.log('parec:', d.toString().trim()));
parec.on('exit', c => { console.log('parec exited', c); setTimeout(() => process.exit(1), 300); });
server.on('error', e => { console.log('server err:', e.message); setTimeout(() => process.exit(1), 500); });
server.listen(PORT, () => console.log('relay on ' + PORT));
'''.replace('@@APORT@@', str(A_PORT))
    open('/content/audio-relay/server.js', 'w').write(srv)
    ok = R('node -c /content/audio-relay/server.js 2>&1').strip()
    print('syntax:', 'OK' if not ok else ok)

STEP('3. Релей файлы', relay_files)

# ---------- 4. Запуск сервисов ----------
def start_services():
    if 'pulse-fail' in R('pactl info 2>&1 | grep "Server Name" || echo pulse-fail'):
        R('pkill -9 -f pulseaudio 2>/dev/null; sleep 1; rm -rf /run/pulse; mkdir -p /run/pulse; chmod 777 /run/pulse')
        sp.Popen('pulseaudio --system --daemonize=yes --exit-idle-time=-1 --disallow-exit --disable-shm > /tmp/pulse.log 2>&1 &', shell=True)
        time.sleep(4)
    print('pulse:', R('pactl info 2>&1 | grep "Server Name" || echo pulse-fail'))
    if 'gamestream' not in R('pactl list short sinks 2>&1'):
        print('null-sink:', R('pactl load-module module-null-sink sink_name=gamestream 2>&1 | tail -1'))

    if not R('ss -tln | grep -E ":' + str(V_PORT) + ' "'):
        R('pkill -9 Xvnc 2>/dev/null; sleep 1; rm -f /tmp/.X99-lock /tmp/.X11-unix/X99')
        sp.Popen('kasmvncserver :99 -geometry 480x360 -depth 24 -rfbport 5901 -websocketPort ' + str(V_PORT) + ' -alwaysshared 2>&1',
                 shell=True, stdout=open('/tmp/kvnc.log', 'w'), stderr=sp.STDOUT)
        time.sleep(8)
    print('Xvnc:', R('ss -tln | grep -E ":' + str(V_PORT) + ' "') or 'Xvnc-fail')
    R('pgrep -x openbox >/dev/null || (DISPLAY=:99 openbox >/dev/null 2>&1 &)')

    if not R('ss -tln | grep -E ":' + str(A_PORT) + ' "'):
        R('pkill -9 -f "node /content/audio-relay" 2>/dev/null; sleep 1')
        sp.Popen('cd /content/audio-relay && nohup node /content/audio-relay/server.js >> /tmp/audio.log 2>&1 &', shell=True)
        time.sleep(3)
    print('relay:', R('tail -1 /tmp/audio.log') or 'check', '|', R('ss -tln | grep -E ":' + str(A_PORT) + ' "'))
    if not R('ss -tln | grep -E ":' + str(A_PORT) + ' "'):
        print('relay-FAIL, log:', R('tail -5 /tmp/audio.log'))

    if not R('pgrep -f "ddnet/DDNet"'):
        R('pkill -9 -f "ddnet/DDNet" 2>/dev/null; sleep 1')
        env = {**os.environ, 'DISPLAY': ':99', 'MESA_GL_VERSION_OVERRIDE': '3.3',
               'MESA_GLSL_VERSION_OVERRIDE': '330', 'LIBGL_ALWAYS_SOFTWARE': '1',
               'GALLIUM_DRIVER': 'llvmpipe', 'LP_NUM_THREADS': '2', 'vblank_mode': '0',
               'SDL_AUDIODRIVER': 'pulse', 'SDL_VIDEODRIVER': 'x11',
               'VK_ICD_FILENAMES': '/nonexistent-icd.json',
               'PULSE_SERVER': 'unix:/run/pulse/native'}
        sp.Popen(['/content/ddnet/DDNet'], cwd='/content/ddnet', env=env,
                 stdout=open('/tmp/dd.log', 'w'), stderr=sp.STDOUT)
        time.sleep(8)
    print('DDNet:', R('pgrep -af "ddnet/DDNet" | grep -v grep | head -1') or 'NO-DDNET')
    WID = R('DISPLAY=:99 xdotool search --onlyvisible --name DDNet 2>&1 | grep -E "^[0-9]+" | head -1').strip()
    if WID:
        R('DISPLAY=:99 xdotool windowactivate --sync ' + WID + '; DISPLAY=:99 xdotool windowmove ' + WID + ' 80 60; DISPLAY=:99 xdotool windowsize ' + WID + ' 480 360')
        print('game window:', WID)

    open('/tmp/frpc.toml', 'w').write('''serverAddr = "vds2.fenst4r.live"
serverPort = 7000
auth.method = "token"
auth.token = "+inL2EtWR5CxUmVIciXz"

[[proxies]]
name = "kasmvnc"
type = "tcp"
localIP = "127.0.0.1"
localPort = @@VPORT@@
remotePort = @@VPORT@@

[[proxies]]
name = "audio"
type = "tcp"
localIP = "127.0.0.1"
localPort = @@APORT@@
remotePort = @@APORT@@
'''.replace('@@VPORT@@', str(V_PORT)).replace('@@APORT@@', str(A_PORT)))
    if not R('pgrep -f "frpc -c /tmp/frpc.toml"'):
        R('pkill -9 -f "frpc -c /tmp/frpc.toml" 2>/dev/null; sleep 1')
        sp.Popen('/usr/local/bin/frpc -c /tmp/frpc.toml >/tmp/frpc.log 2>&1 &', shell=True, stdout=sp.DEVNULL, stderr=sp.STDOUT)
        time.sleep(6)
    print('frpc log:', R('grep -aE "start proxy|login to server|error" /tmp/frpc.log | tail -3') or '(нет строк)')

STEP('4. Запуск', start_services)

# ---------- 5. Watchdog ----------
def watchdog():
    wd = '''#!/bin/bash
V=6901; A=6902
while true; do
  ss -tln | grep -q ":$V " || { rm -f /tmp/.X99-lock /tmp/.X11-unix/X99; kasmvncserver :99 -geometry 480x360 -depth 24 -rfbport 5901 -websocketPort $V -alwaysshared > /tmp/kvnc.log 2>&1 & }
  ss -tln | grep -q ":$A " || { cd /content/audio-relay && nohup node /content/audio-relay/server.js >> /tmp/audio.log 2>&1 & }
  pgrep -f "frpc -c /tmp/frpc.toml" >/dev/null || ( /usr/local/bin/frpc -c /tmp/frpc.toml >> /tmp/frpc.log 2>&1 & )
  pgrep -f "ddnet/DDNet" >/dev/null || { cd /content/ddnet && DISPLAY=:99 MESA_GL_VERSION_OVERRIDE=3.3 MESA_GLSL_VERSION_OVERRIDE=330 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe SDL_AUDIODRIVER=pulse SDL_VIDEODRIVER=x11 VK_ICD_FILENAMES=/nonexistent-icd.json PULSE_SERVER=unix:/run/pulse/native nohup ./DDNet >> /tmp/dd.log 2>&1 & }
  pgrep -x pulseaudio >/dev/null || { pulseaudio --system --daemonize=yes --exit-idle-time=-1 --disallow-exit --disable-shm > /tmp/pulse.log 2>&1 & }
  sleep 10
done
'''
    open('/tmp/watch.sh', 'w').write(wd)
    R('pkill -9 -f "bash /tmp/watch.sh" 2>/dev/null; sleep 1')
    sp.Popen('setsid nohup bash /tmp/watch.sh >/tmp/watch.log 2>&1 &', shell=True)
    time.sleep(4)
    print('watch:', R('pgrep -f "bash /tmp/watch.sh" | head -1') or 'started')

STEP('5. Watchdog', watchdog)

# ---------- 6. Итоговая диагностика ----------
time.sleep(5)
print('=== ИТОГ ===')
print('frpc :', R('pgrep -f "frpc -c /tmp/frpc.toml" | head -1') or 'DEAD')
print('Xvnc :', R('pgrep -f "Xvnc :99" | head -1') or 'DEAD')
print('relay:', R('pgrep -f "node /content/audio-relay/server.js" | head -1') or 'DEAD')
print('DDNet:', R('pgrep -f "ddnet/DDNet" | head -1') or 'DEAD')
print('watch:', R('pgrep -f "bash /tmp/watch.sh" | head -1') or 'DEAD')
print('ports:', R('ss -tln | grep -E ":(6901|6902) "'))
print()
print('================================================================')
print('Видео (отдельно): http://vds2.fenst4r.live:6901/   логин root / testpass')
print('Сайт (видео+звук+фуллскрин): http://vds2.fenst4r.live:6902/')
print('================================================================')
