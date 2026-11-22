## Grimoire: a dual-screen, voice-driven ACP coding client for handhelds and desktops.

import
  std/[os, parseopt, posix, strutils, tables, times],
  pixie, touchkeyboard, windy,
  grimoire/[agent, app, config, voice]

type
  Options = object
    configPath: string
    display: string
    fontSize: float32
    checkPrompt, checkWav, checkTts, saveWav, snapshotDir, profilePath, inputWav: string
    agentStdio: bool
  Screens = object
    top, bottom: Window

const
  Usage = """
grimoire [options]

  --config:PATH        Configuration file (default ~/.config/grimoire/config.json).
  --display:x11|drm    Display backend (default: drm when a DS Plus profile is present).
  --profile:PATH       mono-retro device profile JSON (default: the installed
                       /etc/mono-retro profile whose touchscreen is present).
  --font-size:N        Conversation font size in pixels (default 28).
  --check-agent:TEXT   Without a display, send TEXT to the agent and print the reply.
                       Permission requests are rejected automatically.
  --check-stt:WAV      Without a display, transcribe WAV and print the text.
  --check-tts:TEXT     Without a display, synthesize TEXT into speech-check.wav
                       (written to a file, never played).
  --save-wav:PATH      Also write each recorded turn to PATH for diagnostics.
  --input-wav:PATH     Use this 16-bit mono WAV as the microphone each time it
                       listens, played in real time and followed by quiet, and
                       start listening at once. Spoken replies stay off (tests).
  --agent-stdio        Use this process's stdin/stdout as the ACP agent connection,
                       for an agent started on the host (see host/run-on-rg-ds-plus).
  --snapshot:DIR       Also write each presented screen to DIR/top.png and DIR/bottom.png.
"""
  FrameSleepMs = 15
  DesktopWidth = 1024
  DesktopHeight = 768
  AlsoftConf = "/etc/mono-retro/alsoft.conf"
  ListenAgainSeconds = 0.5
  StdioAgentIn = 10
  StdioAgentOut = 11
  StdioRelay = @["/bin/sh", "-c", "cat <&10 & exec cat >&11"]

var quitSignal: bool

proc onSignal(signal: cint) {.noconv.} =
  ## Request an orderly exit so displays and child processes are released.
  quitSignal = true

proc parseOptions(): Options =
  ## Read command-line options.
  result = Options(configPath: configPath(), display: "auto", fontSize: 28)
  for kind, key, value in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "config": result.configPath = value
      of "display": result.display = value
      of "profile": result.profilePath = value
      of "font-size": result.fontSize = parseFloat(value)
      of "check-agent": result.checkPrompt = value
      of "check-stt": result.checkWav = value
      of "check-tts": result.checkTts = value
      of "save-wav": result.saveWav = value
      of "input-wav": result.inputWav = value
      of "snapshot": result.snapshotDir = value
      of "agent-stdio": result.agentStdio = true
      of "help", "h":
        echo Usage
        quit(0)
      else: quit("Unknown option --" & key & "\n" & Usage, 2)
    else: quit("Unexpected argument " & key & "\n" & Usage, 2)

proc adoptStdioAgent() =
  ## Move the inherited ACP channel to fds the relay child inherits, and keep
  ## stray output away from it: stdin becomes /dev/null and stdout joins stderr.
  if dup2(0, StdioAgentIn) < 0 or dup2(1, StdioAgentOut) < 0:
    raiseOSError(osLastError())
  let devNull = posix.open("/dev/null", O_RDONLY)
  if devNull < 0 or dup2(devNull, 0) < 0 or dup2(2, 1) < 0:
    raiseOSError(osLastError())
  discard posix.close(devNull)

proc checkAgent(config: Config, text: string) =
  ## Run one prompt without a display to qualify the ACP transport.
  initAgentChannels()
  let session = Agent(instructions: config.instructions, sessionMeta: config.sessionMeta)
  let started = epochTime()
  session.connect(config.agent, config.projects[0].cwd, config.mode)
  if session.state != idle:
    quit("Agent connection failed: " & session.error, 1)
  stderr.writeLine "connected to ", session.name, " model=", session.model,
    " in ", (epochTime() - started).formatFloat(ffDecimal, 1), "s"
  stderr.writeLine session.describeSession()
  session.send(text)
  var stopReason = ""
  while stopReason.len == 0:
    let (ready, event) = nextEvent()
    if ready:
      case event.kind
      of agentText: stdout.write(event.text); stdout.flushFile()
      of toolStarted, toolChanged: stderr.writeLine "[tool ", event.status, "] ", event.text
      of permissionAsked:
        stderr.writeLine "[permission rejected automatically] ", event.text
        session.answerPermission("")
      of agentLog: stderr.writeLine "[agent] ", event.text.strip()
      else: discard
    else:
      stopReason = session.poll()
      if stopReason.len == 0: sleep(10)
  stdout.write("\n")
  stderr.writeLine "stop=", stopReason, " total=", (epochTime() - started).formatFloat(ffDecimal, 1), "s"
  session.close()
  if stopReason == "error": quit("Prompt failed: " & session.error, 1)

proc openScreens(backend: string, profile: DeviceProfile): Screens =
  ## Open the upper and lower screens on DRM or as two X11 windows.
  if backend == "drm":
    setLinuxBackend(DrmBackend)
    let size = ivec2(DesktopWidth, DesktopHeight)
    result.top = newWindow("Grimoire", size, linuxOptions = LinuxWindowOptions(
      device: profile.drmDevice, output: profile.outputs[0]))
    result.bottom = newWindow("Grimoire controls", size, linuxOptions = LinuxWindowOptions(
      device: profile.drmDevice, output: profile.outputs[1],
      touchDevice: inputPath(profile.touchName)))
  else:
    setLinuxBackend(X11Backend)
    let size = ivec2(DesktopWidth, DesktopHeight)
    result.top = newWindow("Grimoire", size)
    result.bottom = newWindow("Grimoire controls", size)

proc connectAgent(app: App, screens: Screens, reuse = false) =
  ## Show progress, then (re)connect the agent for the selected project.
  ## With reuse, an idle connection keeps running and only the session changes.
  if app.recorder.recording: app.recorder.stop()
  let switching = reuse and app.agent.canSwitch()
  if not switching: app.agent.close()
  app.agent.state = connecting
  app.clearPermission()
  app.info("Connecting to " & app.project.name & " (" & app.project.cwd & ")…")
  app.drawTop()
  app.drawBottom()
  screens.top.presentPixels(app.top)
  screens.bottom.presentPixels(app.bottom)
  let started = epochTime()
  if switching: app.agent.switchSession(app.project.cwd, app.config.mode)
  else: app.agent.connect(app.config.agent, app.project.cwd, app.config.mode)
  if app.agent.state == idle:
    var text = "Connected to " & app.agent.name
    if app.agent.model.len > 0: text.add " (" & app.agent.model & ")"
    if app.agent.mode.len > 0: text.add ", permission mode " & app.agent.mode
    app.info(text & " in " & (epochTime() - started).formatFloat(ffDecimal, 1) & "s.")
  else:
    if app.config.agent[0].extractFilename() == "grimoire-host-relay":
      app.fail("The development host is not connected. On it, run " &
        "\"make serve-rg-ds-plus RG_DS_PLUS=<handheld address>\", then open the menu " &
        "with START and tap RECONNECT.")
    else:
      app.fail("Agent connection failed: " & app.agent.error)
  app.bottomDirty = true

proc quiet(app: App) =
  ## Stop reading a reply aloud, including speech still being synthesized.
  interruptSpeech()
  app.speaker.silence()
  app.speechPending = 0
  app.speaking = false

proc startListening(app: App) =
  ## Open the microphone for a spoken turn.
  app.quiet()
  app.status = ""
  try:
    app.recorder.start()
  except CatchableError as error:
    app.recorder.error = error.msg
    app.handsFree = false
    app.fail("Microphone: " & error.msg)

proc finishListening(app: App, saveWav: string) =
  ## Close the microphone and send what was heard for recognition.
  app.recorder.stop()
  if app.recorder.seconds < 0.3:
    app.status = "That was too short; tap TALK and speak."
    app.handsFree = false
  else:
    if saveWav.len > 0: app.recorder.saveWav(saveWav)
    app.recorder.submit(app.config.speech)
    app.transcribing = true

proc perform(app: App, action: Action, optionId: string, screens: Screens, saveWav: string) =
  ## Carry out a touch, button or keyboard action.
  case action
  of noAction: discard
  of voiceAction:
    case app.phase
    of listeningPhase: app.finishListening(saveWav)
    of transcribingPhase: discard
    of speakingPhase:
      app.quiet()
      app.handsFree = false
    of thinkingPhase:
      app.handsFree = false
      try:
        app.agent.cancel()
        app.clearPermission()
        app.info("Cancel requested.")
      except CatchableError as error:
        app.fail("Cancel failed: " & error.msg)
    of readyPhase:
      if app.draft.strip().len > 0: app.perform(sendDraft, "", screens, saveWav)
      else:
        app.handsFree = true
        app.startListening()
  of sendDraft:
    let text = app.draft.strip()
    if text.len == 0 or app.agent.state != idle:
      return
    app.quiet()
    app.replyText = ""
    try:
      app.agent.send(text)
      app.addEntry(userEntry, "You: " & text)
      app.draft = ""
      app.status = ""
    except CatchableError as error:
      app.agent.state = failed
      app.agent.error = error.msg
      app.handsFree = false
      app.fail("Send failed: " & error.msg & " Open the menu with START and tap RECONNECT.")
  of clearDraft:
    app.draft = ""
    app.status = ""
  of openKeyboard:
    app.quiet()
    app.handsFree = false
    if app.recorder.recording: app.recorder.stop()
    app.showKeyboard()
  of scrollUp: app.pageUp()
  of scrollDown: app.pageDown()
  of openMenu:
    app.menuOpen = true
    app.typing = false
    app.focus = 0
  of closeMenu: app.menuOpen = false
  of toggleSpeech:
    app.speakReplies = not app.speakReplies
    if not app.speakReplies: app.quiet()
    app.saveSettings()
  of nextPause:
    app.cyclePause()
    app.saveSettings()
  of nextPermissionMode:
    try:
      # Reconnecting keeps the chosen mode.
      app.config.mode = app.agent.nextMode()
      app.saveSettings()
      app.info("Permission mode: " & app.agent.modeName())
    except CatchableError as error:
      app.fail("Could not change the permission mode: " & error.msg)
  of nextProject:
    app.projectIndex = (app.projectIndex + 1) mod app.config.projects.len
    app.connectAgent(screens, reuse = true)
  of reconnect:
    app.menuOpen = false
    app.connectAgent(screens)
  of quit:
    if app.armQuit(): app.quitRequested = true
  of permissionChoice:
    app.agent.answerPermission(optionId)
    app.info("Permission answered: " & optionId)
    app.clearPermission()
  of permissionCancel:
    app.agent.answerPermission("")
    app.info("Permission request cancelled.")
    app.clearPermission()
  app.bottomDirty = true

type
  HardwareButtons = object
    ## Open key devices and the labels of the keys read from each.
    devices: seq[(cint, seq[(int, string)])]

proc openButtons(profile: DeviceProfile): HardwareButtons =
  ## Open the profile's key devices without blocking, skipping missing ones.
  var names: seq[string]
  for (_, device, _) in profile.buttons:
    if device notin names: names.add device
  for name in names:
    let fd = try: posix.open(inputPath(name).cstring, O_RDONLY or O_NONBLOCK)
      except CatchableError: -1.cint
    if fd < 0: continue
    var keys: seq[(int, string)]
    for (label, device, code) in profile.buttons:
      if device == name: keys.add (code, label)
    result.devices.add (fd, keys)

proc pressed(buttons: HardwareButtons): seq[string] =
  ## Drain pending key events and return the labels of keys pressed since.
  type InputEvent = object
    seconds, microseconds: clong
    kind, code: uint16
    value: int32
  var event: InputEvent
  for (fd, keys) in buttons.devices:
    while posix.read(fd, addr event, sizeof(event)) == sizeof(event):
      if event.kind == 1 and event.value == 1:
        for (code, label) in keys:
          if code == int(event.code): result.add label

proc close(buttons: HardwareButtons) =
  ## Close the key devices.
  for (fd, _) in buttons.devices: discard posix.close(fd)

proc handleButton(app: App, label: string, pending: var seq[(Action, string)]) =
  ## Map a hardware key to the current screen. Permission requests stay
  ## touch-only, so a stray key press never answers one.
  if app.agent.permissionPending:
    return
  if label == "START":
    pending.add ((if app.menuOpen: closeMenu else: openMenu), "")
  elif app.typing:
    case label
    of "UP": app.keyboardMove(0, -1)
    of "DOWN": app.keyboardMove(0, 1)
    of "LEFT": app.keyboardMove(-1, 0)
    of "RIGHT": app.keyboardMove(1, 0)
    of "A":
      if app.keyboardActivate() == KeyboardSubmitted: pending.add (sendDraft, "")
    of "B", "BACK": app.closeKeyboard()
    else: discard
  elif app.menuOpen:
    case label
    of "UP", "LEFT": app.moveFocus(-1)
    of "DOWN", "RIGHT": app.moveFocus(1)
    of "A":
      let target = app.focusedButton()
      if target.action != noAction: pending.add (target.action, target.optionId)
    of "B", "BACK": pending.add (closeMenu, "")
    else: discard
  else:
    case label
    of "A": pending.add (voiceAction, "")
    of "UP": pending.add (scrollUp, "")
    of "DOWN": pending.add (scrollDown, "")
    else: discard

proc main() =
  ## Run Grimoire.
  let options = parseOptions()
  var config = loadConfig(options.configPath)
  config.loadSettings(settingsPath(options.configPath))
  if options.agentStdio:
    adoptStdioAgent()
    config.agent = StdioRelay
  if options.checkWav.len > 0:
    echo transcribe(config.speech, readFile(options.checkWav))
    return
  if options.checkTts.len > 0:
    let (pcm, rate, channels) = synthesize(config.speech, options.checkTts)
    if channels != 1: quit("Expected mono speech, got " & $channels & " channels", 1)
    var samples = newSeq[int16](pcm.len div 2)
    if samples.len > 0: copyMem(addr samples[0], unsafeAddr pcm[0], samples.len * 2)
    writeFile("speech-check.wav", wavBytes(samples, rate))
    echo "wrote speech-check.wav: ", samples.len / rate, " s at ", rate, " Hz"
    return
  if options.checkPrompt.len > 0:
    checkAgent(config, options.checkPrompt)
    return

  let profile = detectProfile(options.profilePath)
  let backend = if options.display != "auto": options.display
    elif profile.found: "drm" else: "x11"
  if backend == "drm" and not profile.found:
    quit("No DRM handheld profile with a present touchscreen was found", 1)
  if profile.found and getEnv("ALSOFT_CONF").len == 0 and fileExists(AlsoftConf):
    putEnv("ALSOFT_CONF", AlsoftConf)
  let gainDb = if config.microphoneGainDb != 0: config.microphoneGainDb
    else: profile.microphoneGainDb

  posix.signal(SIGTERM, onSignal)
  posix.signal(SIGINT, onSignal)
  initAgentChannels()
  startVoiceWorker()
  let screens = openScreens(backend, profile)
  let app = newApp(config, gainDb, int(screens.top.framebufferSize.x),
    int(screens.top.framebufferSize.y), options.fontSize)
  app.recorder.reportLevels = true
  app.settingsFile = settingsPath(options.configPath)
  if options.inputWav.len > 0:
    app.recorder.useTestInput(readFile(options.inputWav))
    # Test runs never speak: they may run on a real device's speaker.
    app.speakReplies = false
  if app.bottom.width != int(screens.bottom.framebufferSize.x) or
      app.bottom.height != int(screens.bottom.framebufferSize.y):
    app.bottom = newImage(int(screens.bottom.framebufferSize.x),
      int(screens.bottom.framebufferSize.y))

  var touchStarts: Table[int32, Vec2]
  var pending: seq[(Action, string)]
  screens.bottom.onTouch = proc(event: TouchEvent) =
    case event.phase
    of TouchBegin: touchStarts[event.contact.id] = event.contact.position
    of TouchEnd:
      if event.contact.id in touchStarts:
        let
          start = touchStarts[event.contact.id]
          first = app.hit(start.x, start.y)
          last = app.hit(event.contact.position.x, event.contact.position.y)
        touchStarts.del(event.contact.id)
        if first.action != noAction and first.action == last.action and
            first.optionId == last.optionId:
          pending.add (first.action, first.optionId)
        elif app.typing and not app.agent.permissionPending:
          let point = event.contact.position
          if app.keyboardTap(point.x, point.y) == KeyboardSubmitted:
            pending.add (sendDraft, "")
    of TouchCancel: touchStarts.del(event.contact.id)
    of TouchMove: discard
  when HasX11:
    screens.bottom.onButtonPress = proc(button: windy.Button) =
      case button
      of MouseLeft:
        let position = screens.bottom.mousePos
        if app.typing and not app.agent.permissionPending:
          if app.keyboardTap(float32(position.x), float32(position.y)) == KeyboardSubmitted:
            pending.add (sendDraft, "")
        else:
          let target = app.hit(float32(position.x), float32(position.y))
          if target.action != noAction: pending.add (target.action, target.optionId)
      of KeyEscape:
        pending.add ((if app.menuOpen: closeMenu else: openMenu), "")
      of KeyBackspace:
        if app.typing: app.keyboardBackspace()
      of KeyEnter:
        if app.typing:
          app.typing = false
          pending.add (sendDraft, "")
        elif app.menuOpen: app.handleButton("A", pending)
      of KeyUp, KeyDown:
        if not app.typing: app.handleButton(if button == KeyUp: "UP" else: "DOWN", pending)
      else: discard
    screens.bottom.onRune = proc(rune: Rune) =
      if not app.typing: app.showKeyboard()
      app.keyboardInsert($rune)
    screens.top.onScroll = proc() =
      app.scrollBy(screens.top.scrollDelta.y * 60)

  app.connectAgent(screens)
  if options.inputWav.len > 0 and app.agent.state == idle:
    app.handsFree = true
    app.startListening()
  let hardware = openButtons(profile)
  var
    lastState = ""
    quietSince = epochTime()
  try:
    while not app.quitRequested and not quitSignal:
      pollEvents()
      for label in hardware.pressed():
        app.handleButton(label, pending)
      if screens.top.closeRequested or screens.bottom.closeRequested:
        break
      for (action, optionId) in pending:
        app.perform(action, optionId, screens, options.saveWav)
      pending.setLen(0)
      if app.recorder.poll() and app.recorder.recording:
        if app.recorder.speechEnded() or app.recorder.seconds >= MaxRecordingSeconds:
          app.finishListening(options.saveWav)
        elif app.recorder.noSpeech():
          app.recorder.stop()
          app.handsFree = false
          app.status = "Tap TALK when you want to speak."
          app.bottomDirty = true
      let (hasResult, result) = tryResult()
      if hasResult and result.speech:
        if result.generation == currentSpeech() and app.speechPending > 0:
          dec app.speechPending
        if result.error.len > 0:
          app.info("Speech output failed: " & result.error)
        elif result.generation == currentSpeech():
          app.speaker.play(result.pcm, result.rate, result.channels)
          if app.speaker.error.len > 0:
            app.info("Speaker: " & app.speaker.error)
      elif hasResult:
        app.transcribing = false
        if result.error.len > 0:
          app.fail("Speech recognition failed: " & result.error)
        elif result.text.strip().len == 0:
          app.status = "Nothing was recognized; tap TALK and try again."
          app.handsFree = false
        else:
          let text = result.text.strip()
          app.draft = if app.appendTranscript and app.draft.len > 0: app.draft & " " & text
            else: text
          app.status = ""
          if app.agent.state == idle and not app.agent.permissionPending:
            app.perform(sendDraft, "", screens, options.saveWav)
          else:
            app.handsFree = false
            app.status = "The agent is busy; tap SEND when it finishes."
        app.bottomDirty = true
      let speaking = app.speechPending > 0 or app.speaker.speaking()
      if speaking != app.speaking:
        app.speaking = speaking
        app.bottomDirty = true
      while true:
        let (ready, event) = nextEvent()
        if not ready: break
        app.handle(event)
      let stopReason = app.agent.poll()
      if stopReason.len > 0:
        if stopReason == "error":
          app.fail("Turn failed: " & app.agent.error & " Tap RECONNECT.")
        else:
          app.info("Turn ended: " & stopReason)
          if stopReason != "cancelled" and app.speakReplies and
              app.replyText.strip().len > 0:
            app.speechPending = speak(app.replyText, app.config.speech)
        app.replyText = ""
        if stopReason in ["cancelled", "error"]: app.handsFree = false
        app.clearPermission()
        app.agent.permissionPending = false
        app.topDirty = true
      # Hands-free: listen again once the reply has been read aloud, waiting
      # briefly so the end of playback is not recorded as the next turn.
      if app.phase != readyPhase or app.agent.permissionPending or app.typing or app.menuOpen:
        quietSince = epochTime()
      elif app.handsFree and app.agent.state == idle and app.draft.len == 0 and
          epochTime() - quietSince >= ListenAgainSeconds:
        app.startListening()
        app.bottomDirty = true
      let state = $app.agent.state & $app.agent.permissionPending & $app.phase
      if state != lastState:
        lastState = state
        app.topDirty = true
        app.bottomDirty = true
      if app.topDirty:
        app.drawTop()
        screens.top.presentPixels(app.top)
        if options.snapshotDir.len > 0: app.top.writeFile(options.snapshotDir / "top.png")
      if app.bottomDirty or app.meterDue():
        app.drawBottom()
        screens.bottom.presentPixels(app.bottom)
        if options.snapshotDir.len > 0: app.bottom.writeFile(options.snapshotDir / "bottom.png")
      sleep(FrameSleepMs)
  finally:
    app.agent.close()
    app.recorder.close()
    stopVoiceWorker()
    app.speaker.close()
    hardware.close()
    screens.bottom.close()
    screens.top.close()

when isMainModule:
  main()
