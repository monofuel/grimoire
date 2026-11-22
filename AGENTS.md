# Grimoire

Voice-driven ACP coding client for the RG DS Plus (and X11 desktops).

- Nim for app logic; one import block; `##` doc comment in every proc.
- Dependencies are declared in `grimoire.nimble` and pinned in `nimby.lock`
  (upstream windy, pixie, slappy, curly; ACPort; mono-retro for the touch
  keyboard). Build inside a Nimby workspace synced from the lock. Do not edit
  shared library checkouts here.
- `make desktop`, `make rg-ds-plus` (both run in the `flake.nix` dev shell;
  the cross build links the handheld's copied libraries from
  `GRIMOIRE_TARGET_LIBS`, which can be exported from `local.mk`), `make check`.
- ACP is mandatory: never replace it with direct model calls. The agent runs on
  the development host; the handheld is a thin client. The host runner
  (`host/run-on-rg-ds-plus`) carries ACP over the host's existing pinned SSH
  connection to the handheld (`--agent-stdio`); no handheld credentials.
- Permission requests are answered only by a tap. Never auto-approve.
- The handheld's address can change: look it up each time, keep host-key
  pinning in the untracked `local.mk`, and never disable host-key checking.
- Only one display app may run on the handheld; `grimoire-session` stops and
  always restarts the `mono-retro` service. Do not touch games, saves, kernel,
  network or boot configuration.
- The reusable on-screen keyboard belongs to the Anbernic/mono-retro owner;
  consume it when ready instead of building one here.
- Agent-run tests: use Xvfb with `--snapshot:DIR`, `ALSOFT_DRIVERS=null`, and
  do not open the desktop microphone.
- Agent-run checks must be silent on every machine and route, including the
  handheld's speaker and headphones: use `ALSOFT_DRIVERS=null` or keep spoken
  replies off. A private display or `--input-wav` input does not make a run
  silent. Audible output (TTS, tones, any playback) needs the human's explicit
  approval of that specific run, given at the time; announcing it is not
  permission, and install, qualify or "make it ready" requests never are.
  `--input-wav` runs force spoken replies off; do not work around that, and do
  not open a device microphone for an agent-run test.
