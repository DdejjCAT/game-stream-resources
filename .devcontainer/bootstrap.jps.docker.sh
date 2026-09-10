#!/bin/bash
# Jackbox через портативный docker-образ (game+KasmVNC на 6911).
# Образ тянем с GHCR и запускаем контейнер, который сам умеет дисплей + KasmVNC + игру.
# docker-данные кладём в /tmp (там 100+GB), т.к. системный диск 32GB не вмещает образ.
[ -f /tmp/bootstrap.lock ] && exit 0
touch /tmp/bootstrap.lock
exec > /tmp/bootstrap.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
H=/home/codespace

echo "== docker check =="
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update >/dev/null 2>&1
  sudo apt-get install -y -qq docker.io >/dev/null 2>&1 || echo DOCKER-INSTALL-FAIL
fi

echo "== docker dataroot -> /tmp (без containerd-snapshotter) =="
sudo mkdir -p /tmp/docker-dataroot /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{"data-root": "/tmp/docker-dataroot", "features": {"containerd-snapshotter": false}}
EOF
cat /etc/docker/daemon.json
sudo pkill -9 dockerd 2>/dev/null; sleep 2
sudo bash -c 'nohup dockerd --config-file /etc/docker/daemon.json >/tmp/dockerd.log 2>&1 &'
for i in $(seq 1 20); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker info --format 'ROOT={{.DockerRootDir}} STD={{.Driver}}' 2>&1 | head -1

echo "== pull public image =="
IMGV=${GAME:-latest}
IMG=ghcr.io/ddejjcat/jps-docker/jps-portable-gac:${IMGV}
echo "PULLING $IMG"
PULLED=0
for try in 1 2 3; do
  if timeout 900 sudo docker pull "$IMG"; then
    echo PULL-OK; PULLED=1; break
  else
    echo "PULL-FAIL-$try"
    sudo docker system prune -af >/dev/null 2>&1
    sleep 3
  fi
done
[ "$PULLED" = "1" ] || echo NO-IMAGE-AFTER-RETRIES

echo "== run container on :6911 =="
sudo docker rm -f jps 2>/dev/null || true
sudo docker run -d --name jps --restart unless-stopped -e GAME=${IMGV} -p 6911:6911 -p 6921:6912 "$IMG" && echo RUNS-OK
sleep 8
for i in $(seq 1 20); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1:6911/vnc.html 2>/dev/null)
  echo "VURL-6911-$code"
  [ "$code" = "200" ] && break
  sleep 5
done
sudo docker logs jps 2>&1 | tail -8

echo "JPS-DOCKER-STATE:"
RUNNING=$(sudo docker ps --filter name=jps --format '{{.Status}}' | head -1)
VCODE=$(curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1:6911/vnc.html 2>/dev/null)
echo "STATE: RUNNING=[$RUNNING] VNC=[$VCODE]"
if [ -n "$RUNNING" ] && { [ "$VCODE" = "200" ] || [ "$VCODE" = "" ]; }; then
  echo "STACK-UP-END"
else
  echo "STACK-FAIL" 
fi