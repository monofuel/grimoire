# Grimoire

Voice-control a coding agent from an Anbernic RG DS Plus.

<p align="center">
  <img src="docs/screenshot.png" alt="The agent's answer on the upper screen; Grimoire listening on the lower screen" width="320">
  &nbsp;
  <img src="docs/keyboard.png" alt="The on-screen keyboard on the lower screen" width="320">
</p>

Talk, pause, and Grimoire sends your request. The reply shows on the top
screen and is read aloud.

Grimoire speaks [ACP](https://agentclientprotocol.com/), the open protocol
editors use to talk to coding agents, so any ACP agent works: Claude Code,
Gemini CLI, Codex and more. The agent runs on your computer; the handheld is
the screen and mic.

## Build

```sh
mkdir grimoire-workspace && cd grimoire-workspace
nimby create
git clone https://github.com/monofuel/grimoire
cd grimoire
nimby sync nimby.lock
make desktop rg-ds-plus host-setup
```

## Run

```sh
make run                                       # desktop
make install-rg-ds-plus RG_DS_PLUS=<address>   # copy to the handheld
make serve-rg-ds-plus RG_DS_PLUS=<address>     # then open Grimoire on it
```

The agent is Claude Code unless you set `GRIMOIRE_AGENT` in `local.mk`
(handheld) or `agent` in the config (desktop).

## Configure

`~/.config/grimoire/config.json`: `projects` (folders on your computer) and
`sttUrl` / `ttsUrl` (an OpenAI-compatible speech server).

## License

MIT
