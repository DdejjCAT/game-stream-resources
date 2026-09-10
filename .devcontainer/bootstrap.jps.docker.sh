#!/bin/bash
# Jackbox через портативный docker-образ (game+KasmVNC на 6911).
# Вместо обычной загрузки jackbox (part00/part01 -> AppImage -> extract) тянем публичный
# образ с GHCR и запускаем контейнер, который сам умеет дисплей + KasmVNC + игру.
# Любой порт 6911 наружу через codespaces port-forwarding.
exec > /tmp/bootstrap.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
H=/home/codespace

echo "== docker check =="
docker --version 2>&1 | head -1 || echo NO-DOCKER
command -v docker || sudo apt-get install -y -qq docker.io >/dev/null 2>&1 || echo DOCKER-INSTALL-FAIL

echo "== port forwarding 6911 =="
sudo dpkg -l docker.io >/dev/null 2>&1 && sudo systemctl start docker 2>/dev/null || true

echo "== pull public image =="
if timeout 600 sudo docker pull ghcr.io/ddejjcat/jps-docker/jps-portable-gac:latest; then
  echo PULL-OK
else
  echo PULL-FAIL
fi

echo "== run container on :6911 =="
sudo docker rm -f jps 2>/dev/null || true
sudo docker run -d --name jps --restart unless-stopped -p 6911:6911 -p 6921:6912 ghcr.io/ddejjcat/jps-docker/jps-portable-gac:latest && echo RUNS-OK
sleep 8
for i in $(seq 1 20); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1:6911/vnc.html 2>/dev/null)
  echo "VURL-6911-$code"
  [ "$code" = "200" ] && break
  sleep 5
done
sudo docker logs jps 2>&1 | tail -3

echo "JPS-DOCKER-STATE:"
ss -tln | grep -oE ':6911 ' | head -1 || sudo ss -tln | grep -oE ':6911 ' | head -1 || echo NO-6911
echo "STACK-UP-END"