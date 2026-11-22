version = "0.1.0"
author = "monofuel"
description = "Voice-driven dual-screen ACP coding client for the RG DS Plus and X11 desktops"
license = "MIT"
srcDir = "src"
bin = @["grimoire"]

requires "nim >= 2.2.0"
requires "windy >= 0.5.0"
requires "pixie >= 5.1.0"
requires "slappy >= 0.4.0"
requires "curly >= 1.1.1"
requires "https://github.com/monofuel/ACPort"
# The reusable touch keyboard lives in mono-retro's src/touchkeyboard.nim.
requires "https://github.com/monofuel/mono-retro"
