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

## Run on a desktop

`make run` opens Grimoire as two windows and starts the agent on the same
machine.

## Run on the RG DS Plus

This assumes your handheld runs Linux, that you can already SSH into it from
your computer with a key, and that its user has passwordless `sudo`. Ours runs
Gentoo with the [mono-retro](https://github.com/monofuel/mono-retro) launcher;
the scripts stop and restart its OpenRC service. Read `device/` and `host/`
first: they are short shell scripts.

```sh
make install-rg-ds-plus RG_DS_PLUS=<address>
make serve-rg-ds-plus RG_DS_PLUS=<address>
```

- `install-rg-ds-plus` copies the Grimoire binary and the `device/` scripts to
  `/usr/local/bin` on the handheld with `sudo`, and creates
  `~/.config/grimoire/config.json` there if it is missing.
- `serve-rg-ds-plus` runs on your computer until you stop it. When you open
  Grimoire on the handheld, it starts the agent on your computer and connects
  it to Grimoire over SSH. The handheld never connects to your computer.
- `run-rg-ds-plus` is the alternative: it starts Grimoire on the handheld from
  your computer, pausing the launcher until you quit.

## Choosing the agent

Claude Code is the default: `make host-setup` installs its ACP adapter,
`@agentclientprotocol/claude-agent-acp`, from npm into `build/`. For another
agent, set `GRIMOIRE_AGENT` in `local.mk` (handheld) or `agent` in the config
(desktop) to the command that starts it.

## Configure

`~/.config/grimoire/config.json` needs `projects`: folders on your computer.

Speech uses OpenAI by default: set `OPENAI_API_KEY`. It transcribes with
`gpt-transcribe` and speaks replies with `gpt-realtime-2.1-mini`. To use a
local OpenAI-compatible server instead, such as LFM3-Audio:

```json
{
  "projects": [{"name": "grimoire", "cwd": "/path/on/your/computer"}],
  "speech": {"url": "http://speech-server:8001/v1", "apiKey": "local",
             "sttModel": "lfm3-audio-2b", "sttStyle": "chat",
             "ttsModel": "lfm3-audio-2b", "ttsStyle": "speech", "voice": "female"}
}
```

## License

MIT
