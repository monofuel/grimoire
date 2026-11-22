.PHONY: desktop rg-ds-plus host-setup check run install-rg-ds-plus run-rg-ds-plus serve-rg-ds-plus

NIX_SHELL = nix develop --command bash -c
# Machine-specific settings (device address, user, SSH host-key pinning) can go
# in an untracked local.mk.
-include local.mk
# The handheld's current address; look it up each time on DHCP networks.
RG_DS_PLUS ?=
RG_DS_PLUS_USER ?= $(USER)
RG_DS_PLUS_SSH_OPTS ?= -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5
export GRIMOIRE_DEVICE_USER = $(RG_DS_PLUS_USER)
export GRIMOIRE_SSH_OPTS = $(RG_DS_PLUS_SSH_OPTS)
# The ACP agent the handheld uses, run on this computer; Claude Code if unset.
export GRIMOIRE_AGENT
require-address = $(if $(RG_DS_PLUS),,$(error Set RG_DS_PLUS to the handheld's current address))
SSH_DS = ssh $(RG_DS_PLUS_SSH_OPTS)
SCP_DS = scp $(RG_DS_PLUS_SSH_OPTS)
DEVICE = $(RG_DS_PLUS_USER)@$(RG_DS_PLUS)

# Desktop X11 build: two 1024x768 windows, mouse and keyboard on the lower one.
desktop:
	mkdir -p build
	$(NIX_SHELL) 'nim c -o:build/grimoire src/grimoire.nim'

# RG DS Plus build: DRM on both DSI panels with the lower touchscreen. The
# desktop library paths are cleared so Nix's Nim does not resolve dynlib
# libraries such as libcurl to absolute desktop store paths.
rg-ds-plus:
	mkdir -p build
	$(NIX_SHELL) 'GRIMOIRE_TARGET=arm64 GRIMOIRE_BACKENDS=drm \
	  GRIMOIRE_CC=$$(command -v aarch64-unknown-linux-gnu-gcc) \
	  LD_LIBRARY_PATH= NIX_LDFLAGS= \
	  nim c -o:build/grimoire-rg-ds-plus src/grimoire.nim'

# Install the pinned Claude ACP adapter used by host/grimoire-acp.
host-setup:
	npm install --prefix build/host-tools --ignore-scripts --no-audit --no-fund \
	  --save-exact @agentclientprotocol/claude-agent-acp@0.106.0

check:
	$(NIX_SHELL) 'nim check src/grimoire.nim'

run: desktop
	$(NIX_SHELL) 'build/grimoire'

# Install the handheld binary and session wrapper; RG_DS_PLUS is the current
# DHCP address. An existing ~/.config/grimoire/config.json is left untouched.
# DEVICE_PROFILE copies the ROCKNIX-kernel launcher profile, which is built into
# mono-retro rather than installed under /etc/mono-retro. It is used only when
# its touchscreen is present.
DEVICE_PROFILE ?= $(wildcard ../mono-retro/profiles/rg-ds-plus-rocknix.json)
install-rg-ds-plus: rg-ds-plus
	$(require-address)
	$(SCP_DS) build/grimoire-rg-ds-plus device/grimoire-session device/grimoire-host-relay \
	  device/grimoire-host-attach device/config.json assets/cover.png \
	  $(DEVICE_PROFILE) $(DEVICE):/tmp/
	$(SSH_DS) $(DEVICE) 'set -e; \
	  sudo -n install -m 755 /tmp/grimoire-rg-ds-plus /usr/local/bin/grimoire; \
	  sudo -n install -m 755 /tmp/grimoire-session /usr/local/bin/grimoire-session; \
	  sudo -n install -m 755 /tmp/grimoire-host-relay /usr/local/bin/grimoire-host-relay; \
	  sudo -n install -m 755 /tmp/grimoire-host-attach /usr/local/bin/grimoire-host-attach; \
	  sudo -n install -D -m 644 /tmp/cover.png /usr/local/share/grimoire/cover.png; \
	  mkdir -p ~/.config/grimoire; \
	  test -e ~/.config/grimoire/config.json || cp /tmp/config.json ~/.config/grimoire/config.json; \
	  if [ -n "$(notdir $(DEVICE_PROFILE))" ]; then \
	    mv /tmp/$(notdir $(DEVICE_PROFILE)) ~/.config/grimoire/device-profile.json; fi; \
	  rm -f /tmp/grimoire-rg-ds-plus /tmp/grimoire-session /tmp/grimoire-host-relay \
	    /tmp/grimoire-host-attach /tmp/config.json /tmp/cover.png'

# Start Grimoire on the handheld with the agent running on this host.
run-rg-ds-plus:
	$(require-address)
	host/run-on-rg-ds-plus $(RG_DS_PLUS)

# Keep the agent on this host available to Grimoire opened from the handheld's
# launcher, round after round, until stopped with Ctrl-C.
serve-rg-ds-plus:
	$(require-address)
	host/serve-rg-ds-plus $(RG_DS_PLUS)
