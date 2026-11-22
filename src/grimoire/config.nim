import
  std/[json, os, strutils]

type
  SpeechSettings* = object
    ## An OpenAI-compatible speech API: OpenAI itself by default, or a local
    ## server such as LFM3-Audio.
    url*, apiKey*: string
      ## API base URL; an empty key falls back to OPENAI_API_KEY.
    sttModel*, sttStyle*: string
      ## Recognition model; style "transcriptions" (/audio/transcriptions) or
      ## "chat" (audio sent in a chat completion, as LFM3 expects).
    ttsModel*, ttsStyle*, ttsVoice*: string
      ## Speech model; style "realtime" (the Realtime API) or "speech"
      ## (/audio/speech). An empty voice uses the model's default.
  Project* = object
    name*, cwd*: string
  Config* = object
    agent*: seq[string]
      ## Command and arguments that speak ACP over stdio, locally or through ssh.
    projects*: seq[Project]
      ## Working directories on the host where the agent runs.
    mode*: string
      ## Optional ACP session mode; empty keeps the agent's own default.
    speech*: SpeechSettings
    microphoneGainDb*: float
    instructions*: string
      ## Added to the agent's system prompt; empty keeps only the agent's own.
    sessionMeta*: JsonNode
      ## Passed as `_meta` on each new ACP session, for agent-specific options.
    pauseSeconds*: float
      ## Silence after speech that sends a spoken turn.
    speakReplies*: bool
  DeviceProfile* = object
    found*: bool
    path*, drmDevice*, touchName*: string
    buttons*: seq[(string, string, int)]
      ## Hardware keys as (label, input device name, key code): START, A, B,
      ## BACK and the D-pad directions.
    outputs*: seq[string]
    microphoneGainDb*: float

const
  DefaultInstructions = "The user is talking to you through Grimoire, a voice client on a " &
    "handheld, and your replies are read aloud. Answer in one to three short, plain " &
    "sentences unless they ask for detail. No preamble, recap, headings, lists or tables. " &
    "After doing work, say briefly what you did and anything they must decide; " &
    "don't describe the code itself."
  ProfileDir = "/etc/mono-retro"

proc configPath*(): string =
  ## Return the per-user configuration path.
  getConfigDir() / "grimoire" / "config.json"

proc defaultConfig(): Config =
  ## Run the host wrapper beside this checkout against this checkout.
  let repo = getAppDir().parentDir()
  Config(agent: @[repo / "host" / "grimoire-acp"],
    projects: @[Project(name: "grimoire", cwd: repo)],
    speech: SpeechSettings(url: "https://api.openai.com/v1",
      sttModel: "gpt-transcribe", sttStyle: "transcriptions",
      ttsModel: "gpt-realtime-2.1-mini", ttsStyle: "realtime"),
    pauseSeconds: 2.0,
    instructions: DefaultInstructions, speakReplies: true)

proc loadConfig*(path = configPath()): Config =
  ## Load the configuration file, filling unspecified fields with defaults.
  result = defaultConfig()
  if not fileExists(path):
    return
  let node = parseFile(path)
  if node.hasKey("agent"):
    result.agent.setLen(0)
    for item in node["agent"]: result.agent.add item.getStr()
  if node.hasKey("projects"):
    result.projects.setLen(0)
    for item in node["projects"]:
      result.projects.add Project(name: item["name"].getStr(), cwd: item["cwd"].getStr())
  if node.hasKey("mode"): result.mode = node["mode"].getStr()
  if node.hasKey("speech"):
    let speech = node["speech"]
    for (key, field) in [("url", addr result.speech.url), ("apiKey", addr result.speech.apiKey),
        ("sttModel", addr result.speech.sttModel), ("sttStyle", addr result.speech.sttStyle),
        ("ttsModel", addr result.speech.ttsModel), ("ttsStyle", addr result.speech.ttsStyle),
        ("voice", addr result.speech.ttsVoice)]:
      if speech.hasKey(key): field[] = speech[key].getStr()
  if node.hasKey("instructions"): result.instructions = node["instructions"].getStr()
  if node.hasKey("sessionMeta"): result.sessionMeta = node["sessionMeta"]
  if node.hasKey("speakReplies"): result.speakReplies = node["speakReplies"].getBool()
  if node.hasKey("pauseSeconds"): result.pauseSeconds = node["pauseSeconds"].getFloat()
  if node.hasKey("microphoneGainDb"): result.microphoneGainDb = node["microphoneGainDb"].getFloat()
  if result.agent.len == 0:
    raise newException(ValueError, path & ": agent command is empty")
  if result.projects.len == 0:
    raise newException(ValueError, path & ": no projects configured")
  for project in result.projects:
    if not project.cwd.isAbsolute():
      raise newException(ValueError, path & ": project cwd must be absolute: " & project.cwd)

proc settingsPath*(configPath: string): string =
  ## Return where choices made in Grimoire's menu are kept, beside the config.
  configPath.parentDir() / "settings.json"

proc loadSettings*(config: var Config, path: string) =
  ## Apply menu choices saved by an earlier run over the configuration.
  if not fileExists(path):
    return
  let node = try: parseFile(path) except CatchableError: return
  if node.hasKey("mode"): config.mode = node["mode"].getStr()
  if node.hasKey("pauseSeconds"): config.pauseSeconds = node["pauseSeconds"].getFloat()
  if node.hasKey("speakReplies"): config.speakReplies = node["speakReplies"].getBool()

proc saveSettings*(path, mode: string, pauseSeconds: float, speakReplies: bool) =
  ## Keep the menu choices for the next run.
  try:
    createDir(path.parentDir())
    writeFile(path, $(%*{"mode": mode, "pauseSeconds": pauseSeconds,
      "speakReplies": speakReplies}) & "\n")
  except CatchableError as error:
    stderr.writeLine "Could not save settings: ", error.msg

proc inputDeviceNames(): seq[string] =
  ## List kernel input device names from sysfs.
  for dir in walkDirs("/sys/class/input/event*"):
    let nameFile = dir / "device" / "name"
    if fileExists(nameFile): result.add readFile(nameFile).strip()

proc inputPath*(name: string): string =
  ## Find the /dev/input node of the uniquely named input device.
  for dir in walkDirs("/sys/class/input/event*"):
    let nameFile = dir / "device" / "name"
    if fileExists(nameFile) and readFile(nameFile).strip() == name:
      if result.len > 0:
        raise newException(IOError, "More than one input device is named " & name)
      result = "/dev/input" / dir.extractFilename()
  if result.len == 0:
    raise newException(IOError, "No input device is named " & name)

proc readProfile(path: string, names: seq[string]): DeviceProfile =
  ## Read a mono-retro DRM profile, returning not found unless its touchscreen is present.
  let node = try: parseFile(path) except CatchableError: return
  if node{"display"}.getStr() != "drm" or node{"outputs"}.len != 2:
    return
  let touchName = node{"touchName"}.getStr()
  if touchName notin names:
    return
  result = DeviceProfile(found: true, path: path,
    drmDevice: node{"drmDevice"}.getStr("/dev/dri/card0"), touchName: touchName,
    microphoneGainDb: node{"microphoneGainDb"}.getFloat())
  for output in node["outputs"]: result.outputs.add output.getStr()
  for binding in node{"bindings"}:
    let label = binding{"label"}.getStr()
    if binding{"kind"}.getInt() == 1 and binding{"value"}.getInt() == 1 and
        label in ["START", "A", "B", "BACK", "UP", "DOWN", "LEFT", "RIGHT"]:
      result.buttons.add (label, binding{"device"}.getStr(), binding{"code"}.getInt())

proc detectProfile*(path = ""): DeviceProfile =
  ## Use the given mono-retro DRM profile when its touchscreen is present, or else
  ## select the installed one whose touchscreen is.
  let names = inputDeviceNames()
  if path.len > 0:
    result = readProfile(path, names)
    if result.found:
      return
  if not dirExists(ProfileDir):
    return
  for candidate in walkFiles(ProfileDir / "*.json"):
    result = readProfile(candidate, names)
    if result.found:
      return
