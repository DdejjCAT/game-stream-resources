FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends sudo ca-certificates curl wget git jq xz-utils \
      zip unzip nodejs npm x11-utils xauth imagemagick libvulkan1 mesa-vulkan-drivers \
      xdotool openbox pulseaudio pulseaudio-utils libxfont2 libsdl2-2.0-0 \
      libsdl2-mixer-2.0-0 libfreetype6 \
 && useradd -m -s /bin/bash codespace \
 && echo 'codespace ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
USER codespace
WORKDIR /workspaces/colab_game