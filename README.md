# Grimoire

Voice-control a coding agent from an Anbernic RG DS Plus.

<p align="center">
  <img src="docs/screenshot.png" alt="The agent's answer on the upper screen; Grimoire listening on the lower screen" width="320">
  &nbsp;
  <img src="docs/keyboard.png" alt="The on-screen keyboard on the lower screen" width="320">
</p>

Tap TALK and speak. Grimoire sends your request when you pause, shows the
reply on the top screen, reads it aloud, and listens again. The agent runs on
your computer over [ACP](https://agentclientprotocol.com/); the handheld is
just the remote. Permission requests are answered by tapping a button.

## Build

Uses [Nimby](https://github.com/treeform/nimby) and Nix flakes.

```sh
mkdir grimoire-workspace && cd grimoire-workspace
nimby create
git clone https://github.com/monofuel/grimoire
cd grimoire
nimby sync nimby.lock
make desktop       # two X11 windows
make rg-ds-plus    # handheld build
make host-setup    # Claude Code ACP adapter
```

## Run

```sh
make run                                      # desktop
make install-rg-ds-plus RG_DS_PLUS=<address>
make serve-rg-ds-plus RG_DS_PLUS=<address>    # then open Grimoire on the handheld
```

Put `RG_DS_PLUS_USER`, `RG_DS_PLUS_SSH_OPTS` and `GRIMOIRE_TARGET_LIBS` in
`local.mk`.

## Configure

`~/.config/grimoire/config.json`:

```json
{
  "projects": [{"name": "grimoire", "cwd": "/path/on/the/agent/host"}],
  "sttUrl": "http://speech-server:8001/v1/chat/completions",
  "ttsUrl": "http://speech-server:8001/v1/audio/speech"
}
```

Speech uses any OpenAI-compatible endpoint, such as LFM3-Audio. Other keys:
`agent`, `mode`, `pauseSeconds`, `instructions`, `sessionMeta`.

## License

MIT. Roboto is Apache 2.0.
