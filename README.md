# Grimoire

Voice-control a coding agent from an Anbernic RG DS Plus.

<p align="center">
  <img src="docs/screenshot.png" alt="The agent's answer on the upper screen; Grimoire listening on the lower screen" width="320">
  &nbsp;
  <img src="docs/keyboard.png" alt="The on-screen keyboard on the lower screen" width="320">
</p>

Talk, pause, and Grimoire sends your request. The reply shows on the top
screen and is read aloud. You can also type with the touchscreen keyboard;
permission requests wait for you to tap an answer.

Grimoire speaks [ACP](https://agentclientprotocol.com/), the open protocol
editors use to talk to coding agents, so any ACP agent works: Claude Code,
Gemini CLI, Codex and more. The agent runs on your computer; the handheld is
the screen and mic.

## Build

On an x86-64 Linux computer, you'll need:

- Git, Make and Nix with flakes enabled. `make` uses `flake.nix` to supply Nim,
  the compiler and native libraries.
- Nimby 0.2.3 or newer to fetch the dependencies pinned in `nimby.lock`.
- An ACP agent installed and authenticated on that computer. The default
  Claude Code adapter also needs Node.js and npm.

```sh
mkdir grimoire-workspace && cd grimoire-workspace
nimby create
git clone https://github.com/monofuel/grimoire
cd grimoire
nimby sync nimby.lock
```

The current handheld build needs copied device libraries; see the paths in
the [cross-build configuration](config.nims).

## Configure

Installation creates `~/.config/grimoire/config.json` on the handheld.
Edit its `projects` to point to folders on the computer running the agent,
and keep the `agent` entry that connects to the host runner:

```json
{
  "agent": ["/usr/local/bin/grimoire-host-relay"],
  "projects": [{"name": "my-project", "cwd": "/absolute/path/to/my-project"}]
}
```

### Agent

Claude Code is the default; after installing and signing in to Claude Code
on your computer, install its ACP adapter:

```sh
make host-setup
```

For another agent, set `GRIMOIRE_AGENT` in the computer's untracked `local.mk`
to its ACP command.
`host-setup` is only needed for the default Claude Code adapter.

### Speech

Speech recognition and playback use
[openai_leap](https://github.com/monofuel/openai_leap). OpenAI is the default,
using `gpt-transcribe` for recognition and `gpt-realtime-2.1-mini` for spoken
replies. Set `OPENAI_API_KEY` in Grimoire's environment, or add a `speech`
object with an `apiKey` to its configuration on the device. The host runner
does not forward your computer's environment.

To use a local OpenAI-compatible server such as LFM3-Audio, add this `speech`
object to the same configuration instead:

```json
{
  "speech": {
    "url": "http://speech-server:8001/v1",
    "apiKey": "local",
    "sttModel": "lfm3-audio-2b", "sttStyle": "chat",
    "ttsModel": "lfm3-audio-2b", "ttsStyle": "speech", "voice": "female"
  }
}
```

The handheld must be able to reach that speech server.

## Run on the RG DS Plus

The current project defaults have been tested on a custom Gentoo installation
on the RG DS Plus. BananaOS has not been tested yet.

The included session scripts use the
[mono-retro](https://github.com/monofuel/mono-retro) launcher and OpenRC.
Installation requires key-based SSH access from your computer to the handheld
and passwordless `sudo` on the device.

Find the handheld's current address, then install from your computer:

```sh
make install-rg-ds-plus RG_DS_PLUS=<address>
```

This builds the handheld binary, installs it and the session scripts under
`/usr/local/bin`, and creates the device configuration if it is missing.
Existing configuration is preserved. Set the device's project paths and
speech configuration as described above, then start your first session from
your computer:

```sh
make run-rg-ds-plus RG_DS_PLUS=<address>
```

This starts Grimoire on the handheld and the agent on your computer, carrying
ACP over SSH; the handheld needs no credentials for your computer.

If your launcher already has a Grimoire entry, you can instead leave
`make serve-rg-ds-plus RG_DS_PLUS=<address>` running on your computer and open
Grimoire from the handheld's Apps menu. Installation does not add that menu entry.

Press Start for the menu, then Quit to return to the launcher.
The session script stops mono-retro while Grimoire uses the displays and
restarts it when Grimoire exits.

## Desktop debugging

For development, `make run` builds Grimoire and opens its two screens as X11
windows on your Linux computer. Use a local `~/.config/grimoire/config.json`
with your project and speech settings. Omit `agent` to use the default host
adapter, or set it to an array containing your ACP command and its arguments.

## License

MIT
