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

Grimoire is written in Nim and also runs on Linux desktops, with the two
screens shown in separate X11 windows.

## Build

On an x86-64 Linux computer, you'll need:

- Git, Make and Nix with flakes enabled. `make` uses `flake.nix` to supply Nim,
  native libraries and the ARM64 cross compiler.
- Nimby 0.2.3 or newer to fetch the dependencies pinned in `nimby.lock`.
- An ACP agent installed and authenticated on that computer. The default
  Claude Code adapter also needs Node.js and npm.

```sh
mkdir grimoire-workspace && cd grimoire-workspace
nimby create
git clone https://github.com/monofuel/grimoire
cd grimoire
nimby sync nimby.lock
make desktop
```

The handheld build needs libraries copied from your device; see below before
running `make rg-ds-plus`.

## Configure

Grimoire reads `~/.config/grimoire/config.json` on the machine running its
interface: your computer for desktop use, or the handheld for handheld use.
The project paths always refer to folders on the computer running the agent.

For desktop use, create the configuration file with your project path:

```json
{
  "projects": [{"name": "my-project", "cwd": "/absolute/path/to/my-project"}]
}
```

For handheld use, installation creates this file on the device. Edit its
`projects` there and keep the existing `agent` entry, which connects to the
host runner.

### Agent

Claude Code is the default; after installing and signing in to Claude Code
on your computer, install its ACP adapter:

```sh
make host-setup
```

For another agent, set `GRIMOIRE_AGENT` in the computer's untracked `local.mk`
to its ACP command when using the handheld. For desktop use, set `agent` in
the JSON configuration to an array containing the command and its arguments.
`host-setup` is only needed for the default Claude Code adapter.

### Speech

Speech recognition and playback use
[openai_leap](https://github.com/monofuel/openai_leap). OpenAI is the default,
using `gpt-transcribe` for recognition and `gpt-realtime-2.1-mini` for spoken
replies. Set `OPENAI_API_KEY` in Grimoire's environment, or add a `speech`
object with an `apiKey` to its configuration. For handheld use, configure the
key on the device; the host runner does not forward your computer's environment.

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

The machine running Grimoire must be able to reach that speech server.

## Run on a desktop

With your agent and speech configured, run `make run`. It opens two X11
windows and starts the agent on the same computer.

## Run on the RG DS Plus

The supplied scripts target a Linux handheld with the
[mono-retro](https://github.com/monofuel/mono-retro) launcher and its OpenRC
service; our device runs Gentoo. The device needs a matching mono-retro
display/input profile. Your computer must
already have key-based SSH access to the handheld, with its host key verified,
and the handheld user needs passwordless `sudo`.

Before cross-building, copy the handheld's ARM64 libraries into a directory
on your computer: libdrm, libevdev, libudev, OpenAL and glibc, including
`ld-linux-aarch64.so.1`. Preserve the library symlinks and their targets.
Point the build at that directory in an untracked `local.mk`:

```make
export GRIMOIRE_TARGET_LIBS = /absolute/path/to/arm64-libs
RG_DS_PLUS_USER = your-handheld-user
```

The default library directory is `../mono-retro/build/arm64-libs` if you
already have it populated.

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

## License

MIT
