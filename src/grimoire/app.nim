import
  std/[strformat, strutils, tables, times],
  pixie, touchkeyboard,
  ./[agent, config, voice]

type
  EntryKind* = enum
    userEntry, agentEntry, thoughtEntry, toolEntry, planEntry, infoEntry, errorEntry
  Entry = object
    kind: EntryKind
    text: string
    arrangement: Arrangement
    height: float32
    width: float32
  Action* = enum
    noAction, voiceAction, sendDraft, clearDraft, openKeyboard, scrollUp, scrollDown,
    openMenu, closeMenu, toggleSpeech, nextPause, nextPermissionMode, nextProject, reconnect, quit,
    permissionChoice, permissionCancel
  Phase* = enum
    ## What the voice loop is doing, which decides the main button.
    readyPhase, listeningPhase, transcribingPhase, thinkingPhase, speakingPhase
  TouchTarget* = object
    action*: Action
    label: string
    rect: Rect
    enabled: bool
    accent: bool
    optionId*: string
  PermissionPrompt = object
    title, detail: string
    options: seq[(string, string)]
  App* = ref object
    config*: Config
    projectIndex*: int
    agent*: Agent
    recorder*: Recorder
    transcribing*: bool
    speaker*: Speaker
    speaking*: bool
      ## Reply audio is being synthesized or played.
    speechPending*: int
      ## Speech results still expected for the current reply.
    handsFree*: bool
      ## Listen again after a spoken turn's reply, until a turn hears nothing.
    speakReplies*: bool
    keyboard*: TouchKeyboard
    typing*: bool
    keyboardArea: KeyboardLayout
    menuOpen*: bool
    focus*: int
      ## Index of the menu button the D-pad has selected.
    settingsFile*: string
      ## Where menu choices are saved; empty to keep them for this run only.
    replyText*: string
      ## Agent text of the current turn, read aloud when the turn ends.
    appendTranscript*: bool
    draft*: string
    status*: string
    log: seq[Entry]
    toolEntries: Table[string, int]
    scroll: float32
    permission: PermissionPrompt
    buttons: seq[TouchTarget]
    quitArmedAt: float
    quitRequested*: bool
    font, smallFont, headerFont, buttonFont: Font
    top*, bottom*: Image
    topDirty*, bottomDirty*: bool
    lastMeterDraw: float

const
  FontBytes = staticRead("../../assets/Roboto-Regular.ttf")
  Background = parseHtmlColor("#101418")
  Panel = parseHtmlColor("#1c232c")
  PanelLight = parseHtmlColor("#2a3440")
  TextColor = parseHtmlColor("#e8e8e8")
  MutedColor = parseHtmlColor("#8a929c")
  UserColor = parseHtmlColor("#6ec6ff")
  ToolColor = parseHtmlColor("#ffb74d")
  ErrorColor = parseHtmlColor("#ff6b6b")
  GoodColor = parseHtmlColor("#7bd88f")
  RecordColor = parseHtmlColor("#e0464e")
  AccentColor = parseHtmlColor("#3d6fd6")
  Margin = 16'f32
  HeaderHeight = 56'f32
  ScrollStep = 240'f32
  QuitConfirmSeconds = 3.0
  PauseChoices = [1.2, 2.0, 3.0, 5.0]
  MeterIntervalSeconds = 0.1
  MaxThoughtChars = 280
  MaxLogEntries = 400

proc project*(app: App): Project =
  ## Return the selected project.
  app.config.projects[app.projectIndex]

proc newApp*(config: Config, gainDb: float, width, height: int, fontSize: float32): App =
  ## Create the application state and the two screen images.
  let typeface = parseTtf(FontBytes)
  result = App(config: config, agent: Agent(instructions: config.instructions, sessionMeta: config.sessionMeta), recorder: newRecorder(gainDb), speaker: Speaker(),
    top: newImage(width, height), bottom: newImage(width, height),
    topDirty: true, bottomDirty: true, speakReplies: config.speakReplies)
  result.recorder.endSeconds = config.pauseSeconds
  result.font = newFont(typeface)
  result.font.size = fontSize
  result.font.paint.color = TextColor
  result.smallFont = newFont(typeface)
  result.smallFont.size = fontSize * 0.8
  result.headerFont = newFont(typeface)
  result.headerFont.size = 26
  result.buttonFont = newFont(typeface)
  result.buttonFont.size = 30

proc colorFor(kind: EntryKind): Color =
  ## Pick the text color for a conversation entry.
  case kind
  of userEntry: UserColor
  of agentEntry: TextColor
  of thoughtEntry, infoEntry: MutedColor
  of toolEntry, planEntry: ToolColor
  of errorEntry: ErrorColor

proc layout(app: App, entry: var Entry, width: float32) =
  ## Typeset an entry for the given column width.
  let font = if entry.kind in {thoughtEntry, infoEntry, toolEntry, planEntry}:
      app.smallFont.copy() else: app.font.copy()
  font.paint.color = colorFor(entry.kind)
  let text = if entry.text.len == 0: " " else: entry.text
  entry.arrangement = typeset(@[newSpan(text, font)], vec2(width, 0))
  entry.height = entry.arrangement.layoutBounds().y
  entry.width = width

proc addEntry*(app: App, kind: EntryKind, text: string) =
  ## Append a conversation entry and scroll to it.
  app.log.add Entry(kind: kind, text: text)
  if app.log.len > MaxLogEntries:
    app.log.delete(0)
    app.toolEntries.clear()
  app.scroll = 0
  app.topDirty = true

proc appendText(app: App, kind: EntryKind, text: string) =
  ## Extend the last entry of this kind, or start a new one.
  if app.log.len > 0 and app.log[^1].kind == kind:
    app.log[^1].text.add text
    if kind == thoughtEntry and app.log[^1].text.len > MaxThoughtChars:
      app.log[^1].text = "…" & app.log[^1].text[^MaxThoughtChars .. ^1]
    app.log[^1].width = 0
    app.topDirty = true
  else:
    app.addEntry(kind, text)

proc info*(app: App, text: string) =
  ## Show a status message in the conversation.
  app.addEntry(infoEntry, text)

proc fail*(app: App, text: string) =
  ## Show an error in the conversation.
  app.addEntry(errorEntry, text)

proc handle*(app: App, event: AgentEvent) =
  ## Apply one streamed agent event to the conversation.
  case event.kind
  of agentText:
    app.appendText(agentEntry, event.text)
    app.replyText.add event.text
  of thought: app.appendText(thoughtEntry, event.text)
  of toolStarted:
    app.addEntry(toolEntry, &"[{event.status}] {event.text}")
    app.toolEntries[event.toolId] = app.log.high
  of toolChanged:
    let index = app.toolEntries.getOrDefault(event.toolId, -1)
    if index in 0 .. app.log.high:
      var title = app.log[index].text
      let closing = title.find("] ")
      if closing >= 0: title = title[closing + 2 .. ^1]
      if event.text.len > 0: title = event.text
      let status = if event.status.len > 0: event.status else: "update"
      app.log[index].text = &"[{status}] {title}"
      app.log[index].width = 0
      app.topDirty = true
  of planChanged: app.addEntry(planEntry, "Plan:\n" & event.text)
  of permissionAsked:
    app.permission = PermissionPrompt(title: event.text, detail: event.status,
      options: event.options)
    app.agent.permissionPending = true
    app.addEntry(toolEntry, "Permission requested: " & event.text)
    app.bottomDirty = true
  of agentLog: discard

proc fillRoundRect(image: Image, rect: Rect, color: Color) =
  ## Fill a rounded rectangle.
  let ctx = newContext(image)
  ctx.fillStyle = color
  ctx.fillRoundedRect(rect, 12)

proc drawText(image: Image, font: Font, text: string, rect: Rect, color: Color,
    hAlign = LeftAlign, vAlign = TopAlign) =
  ## Draw wrapped text clipped to its rectangle's width.
  let styled = font.copy()
  styled.paint.color = color
  image.fillText(styled.typeset(text, vec2(rect.w, rect.h), hAlign, vAlign),
    translate(vec2(rect.x, rect.y)))

proc stateLabel(app: App): (string, Color) =
  ## Describe the agent connection for the header.
  case app.agent.state
  of disconnected: ("disconnected", MutedColor)
  of connecting: ("connecting…", ToolColor)
  of idle: ("idle", GoodColor)
  of working:
    if app.agent.permissionPending: ("needs permission", ToolColor)
    else: ("working…", UserColor)
  of cancelling: ("cancelling…", ToolColor)
  of failed: ("error", ErrorColor)

proc drawTop*(app: App) =
  ## Render the conversation and agent status on the upper screen.
  let image = app.top
  image.fill(Background)
  let (label, color) = app.stateLabel()
  var right = label
  if app.agent.mode.len > 0: right = app.agent.modeName() & " · " & right
  if app.agent.model.len > 0: right = app.agent.model & " · " & right
  let width = float32(image.width) - Margin * 2
  for entry in app.log.mitems:
    if entry.width != width: app.layout(entry, width)
  var y = float32(image.height) - Margin + app.scroll
  var index = app.log.high
  while index >= 0 and y > HeaderHeight:
    let entry = app.log[index]
    y -= entry.height
    if y < float32(image.height):
      image.fillText(entry.arrangement, translate(vec2(Margin, y)))
    y -= 10
    dec index
  if app.log.len == 0:
    image.drawText(app.font, "Speak a request on the lower screen. The agent's reply streams here.",
      rect(Margin, HeaderHeight + 40, width, 200), MutedColor)
  if app.scroll > 0:
    image.drawText(app.smallFont, "newer text below", rect(Margin, float32(image.height) - 40,
      width, 30), MutedColor, RightAlign)
  # Keep the header readable when long entries scroll underneath it.
  image.fillRoundRect(rect(0, 0, float32(image.width), HeaderHeight), Panel)
  image.drawText(app.headerFont, "Grimoire · " & app.project.name,
    rect(Margin, 12, 600, 40), TextColor)
  image.drawText(app.headerFont, right,
    rect(float32(image.width) - 520, 12, 520 - Margin, 40), color, RightAlign)
  app.topDirty = false

proc button(app: App, action: Action, label: string, rect: Rect, enabled = true,
    accent = false, optionId = "") =
  ## Register a touch target for this frame.
  app.buttons.add TouchTarget(action: action, label: label, rect: rect, enabled: enabled,
    accent: accent, optionId: optionId)

proc phase*(app: App): Phase =
  ## Report the voice loop's current step.
  if app.recorder.recording: listeningPhase
  elif app.transcribing: transcribingPhase
  elif app.speaking: speakingPhase
  elif app.agent.state in {working, cancelling}: thinkingPhase
  else: readyPhase

proc layoutButtons(app: App, width, height: float32) =
  ## Build the lower screen's touch targets for the current state.
  app.buttons.setLen(0)
  let
    gap = 12'f32
    full = width - Margin * 2
    rowHeight = 100'f32
    row2 = height - Margin - rowHeight
    row1 = row2 - gap - rowHeight - 20
    quarter = (full - gap * 3) / 4
  if app.agent.permissionPending:
    var y = 300'f32
    let optionHeight = 86'f32
    for (id, name) in app.permission.options:
      app.button(permissionChoice, name, rect(Margin, y, full, optionHeight),
        accent = true, optionId = id)
      y += optionHeight + gap
    app.button(permissionCancel, "Cancel request", rect(Margin, y, full, optionHeight))
    return
  if app.menuOpen:
    let
      itemHeight = 84'f32
      half = (full - gap) / 2
    var y = 84'f32
    app.button(closeMenu, "BACK TO GRIMOIRE", rect(Margin, y, full, itemHeight), accent = true)
    y += itemHeight + gap
    app.button(toggleSpeech, "SPOKEN REPLIES: " & (if app.speakReplies: "ON" else: "OFF"),
      rect(Margin, y, half, itemHeight))
    app.button(nextPause, &"PAUSE TO SEND: {app.recorder.endSeconds:.1f} s",
      rect(Margin + half + gap, y, half, itemHeight))
    y += itemHeight + gap
    app.button(nextPermissionMode, "PERMISSIONS: " & app.agent.modeName() & " >",
      rect(Margin, y, full, itemHeight), app.agent.state == idle and app.agent.modes.len > 1)
    y += itemHeight + gap
    app.button(nextProject, "PROJECT: " & app.project.name & " >", rect(Margin, y, half, itemHeight),
      app.config.projects.len > 1 and app.agent.state in {idle, failed, disconnected})
    app.button(reconnect, "RECONNECT", rect(Margin + half + gap, y, half, itemHeight),
      app.agent.state != connecting)
    y += itemHeight + gap
    let quitLabel = if epochTime() - app.quitArmedAt < QuitConfirmSeconds: "TAP AGAIN TO QUIT"
      else: "QUIT GRIMOIRE"
    app.button(quit, quitLabel, rect(Margin, y, full, itemHeight))
    return
  let ready = app.agent.state == idle
  let (label, enabled, accent) = case app.phase
    of listeningPhase: ("SEND NOW", true, true)
    of transcribingPhase: ("TRANSCRIBING…", false, false)
    of speakingPhase: ("STOP SPEAKING", true, false)
    of thinkingPhase: ("CANCEL", app.agent.state == working, false)
    of readyPhase:
      if app.draft.strip().len > 0: ("SEND", ready, true)
      else: ("TALK", app.agent.state != connecting, true)
  app.button(voiceAction, label, rect(Margin, row1, full, rowHeight + 20), enabled, accent)
  proc cell(index: int): Rect =
    rect(Margin + float32(index) * (quarter + gap), row2, quarter, rowHeight)
  app.button(openKeyboard, "KEYBOARD", cell(0), app.phase != transcribingPhase)
  app.button(clearDraft, "CLEAR", cell(1), app.draft.len > 0 and app.phase == readyPhase)
  app.button(scrollUp, "UP", cell(2))
  app.button(scrollDown, "DOWN", cell(3), app.scroll > 0)

proc showKeyboard*(app: App) =
  ## Open the shared touch keyboard on the current draft.
  app.keyboard = newTouchKeyboard(app.draft, masked = false, label = "Message",
    submitLabel = "Send")
  app.typing = true
  app.bottomDirty = true

proc keyboardTap*(app: App, x, y: float32): KeyboardResult =
  ## Pass a lower-screen tap to the keyboard. The draft follows every edit, so
  ## closing the keyboard keeps it.
  result = app.keyboard.tap(app.keyboardArea, vec2(x, y))
  case result
  of KeyboardEdited: app.draft = app.keyboard.text
  of KeyboardSubmitted, KeyboardCancelled:
    app.draft = app.keyboard.text
    app.typing = false
  else: discard
  app.bottomDirty = true

proc keyboardInsert*(app: App, text: string) =
  ## Type physical-keyboard text into the open touch keyboard.
  if app.keyboard.insert(text) == KeyboardEdited:
    app.draft = app.keyboard.text
    app.bottomDirty = true

proc keyboardBackspace*(app: App) =
  ## Delete before the cursor in the open touch keyboard.
  if app.keyboard.backspace() == KeyboardEdited:
    app.draft = app.keyboard.text
    app.bottomDirty = true

proc keyboardMove*(app: App, dx, dy: int) =
  ## Move the touch keyboard's controller focus.
  discard app.keyboard.moveFocus(app.keyboardArea, dx, dy)
  app.bottomDirty = true

proc keyboardActivate*(app: App): KeyboardResult =
  ## Press the focused key, as a tap on it would.
  result = app.keyboard.activateFocused(app.keyboardArea)
  case result
  of KeyboardEdited: app.draft = app.keyboard.text
  of KeyboardSubmitted, KeyboardCancelled:
    app.draft = app.keyboard.text
    app.typing = false
  else: discard
  app.bottomDirty = true

proc closeKeyboard*(app: App) =
  ## Leave the keyboard, keeping the draft.
  app.draft = app.keyboard.text
  app.typing = false
  app.bottomDirty = true

proc moveFocus*(app: App, step: int) =
  ## Select the next or previous enabled menu button.
  var enabled: seq[int]
  for i, button in app.buttons:
    if button.enabled: enabled.add i
  if enabled.len == 0: return
  var position = enabled.find(app.focus)
  position = if position < 0: 0 else: (position + step + enabled.len) mod enabled.len
  app.focus = enabled[position]
  app.bottomDirty = true

proc focusedButton*(app: App): TouchTarget =
  ## Return the menu button the D-pad has selected, if it is enabled.
  if app.focus in 0 .. app.buttons.high and app.buttons[app.focus].enabled:
    result = app.buttons[app.focus]

proc saveSettings*(app: App) =
  ## Remember the menu choices for the next run.
  if app.settingsFile.len > 0:
    saveSettings(app.settingsFile, app.config.mode, app.recorder.endSeconds, app.speakReplies)

proc cyclePause*(app: App) =
  ## Step through the silence lengths that end a spoken turn.
  var next = PauseChoices[0]
  for choice in PauseChoices:
    if choice > app.recorder.endSeconds + 0.01:
      next = choice
      break
  app.recorder.endSeconds = next

proc drawBottom*(app: App) =
  ## Render the voice status, draft and controls on the touch screen.
  let
    image = app.bottom
    width = float32(image.width)
    height = float32(image.height)
  image.fill(Background)
  if app.typing and not app.agent.permissionPending:
    app.buttons.setLen(0)
    app.keyboardArea = app.keyboard.keyboardLayout(rect(0, 0, width, height))
    app.keyboard.render(image, app.keyboardArea, app.font.copy())
    app.bottomDirty = false
    return
  app.layoutButtons(width, height)
  image.fillRoundRect(rect(0, 0, width, 64), Panel)
  var (statusText, statusColor) = case app.phase
    of listeningPhase: ("Listening… pause to send", RecordColor)
    of transcribingPhase: ("Transcribing…", UserColor)
    of thinkingPhase:
      if app.agent.state == cancelling: ("Cancelling…", ToolColor) else: ("Thinking…", UserColor)
    of speakingPhase: ("Speaking…", GoodColor)
    of readyPhase: ("Ready", MutedColor)
  if app.phase == readyPhase and app.recorder.error.len > 0:
    (statusText, statusColor) = ("Mic error", ErrorColor)
  if app.menuOpen: (statusText, statusColor) = ("Menu", TextColor)
  image.drawText(app.headerFont, statusText, rect(Margin, 14, 420, 40), statusColor)
  if app.recorder.recording:
    let meter = rect(450, 22, width - 450 - Margin, 20)
    image.fillRoundRect(meter, PanelLight)
    let level = clamp((app.recorder.peakDb + 60) / 60, 0, 1)
    let fillColor = if app.recorder.peakDb > -3: ErrorColor else: GoodColor
    image.fillRoundRect(rect(meter.x, meter.y, max(12, meter.w * level), meter.h), fillColor)
  elif not app.menuOpen:
    image.drawText(app.smallFont, "START: menu", rect(width - 260 - Margin, 18, 260, 32),
      MutedColor, RightAlign)
  if app.agent.permissionPending:
    image.drawText(app.headerFont, "The agent asks for permission:", rect(Margin, 80,
      width - Margin * 2, 40), ToolColor)
    image.drawText(app.font, app.permission.title, rect(Margin, 120, width - Margin * 2, 80),
      TextColor)
    image.drawText(app.smallFont, app.permission.detail, rect(Margin, 196, width - Margin * 2,
      96), MutedColor)
  elif not app.menuOpen:
    let box = rect(Margin, 76, width - Margin * 2, app.buttons[0].rect.y - 76 - 12)
    image.fillRoundRect(box, Panel)
    let inner = rect(box.x + 14, box.y + 12, box.w - 28, box.h - 24)
    if app.draft.len > 0:
      image.drawText(app.font, app.draft, inner, TextColor)
    else:
      let hint = if app.status.len > 0: app.status
        else:
          case app.phase
          of listeningPhase: "Speak your request. Grimoire sends it when you pause."
          of transcribingPhase: "Turning your speech into text…"
          of thinkingPhase: "The agent is working. Its reply appears on the top screen."
          of speakingPhase: "Reading the reply aloud. Grimoire listens again afterwards."
          of readyPhase: "Tap TALK and speak, or open the keyboard."
      image.drawText(app.font, hint, inner, MutedColor)
  for button in app.buttons:
    let fillColor = if not button.enabled: Panel
      elif button.action == voiceAction and app.recorder.recording: RecordColor
      elif button.accent: AccentColor
      else: PanelLight
    image.fillRoundRect(button.rect, fillColor)
    image.drawText(app.buttonFont, button.label, button.rect,
      if button.enabled: TextColor else: MutedColor, CenterAlign, MiddleAlign)
  if app.menuOpen and app.focus in 0 .. app.buttons.high:
    let ctx = newContext(image)
    ctx.strokeStyle = TextColor
    ctx.lineWidth = 4
    ctx.strokeRoundedRect(app.buttons[app.focus].rect, 12)
  app.bottomDirty = false
  app.lastMeterDraw = epochTime()

proc meterDue*(app: App): bool =
  ## Report whether the live level meter should be redrawn.
  app.recorder.recording and epochTime() - app.lastMeterDraw >= MeterIntervalSeconds

proc hit*(app: App, x, y: float32): TouchTarget =
  ## Find the enabled touch target at a lower-screen position.
  for button in app.buttons:
    if button.enabled and button.rect.overlaps(vec2(x, y)):
      return button

proc scrollBy*(app: App, amount: float32) =
  ## Scroll the conversation; positive values reveal older text.
  app.scroll = max(0, app.scroll + amount)
  app.topDirty = true
  app.bottomDirty = true

proc pageUp*(app: App) =
  ## Reveal older conversation text.
  app.scrollBy(ScrollStep)

proc pageDown*(app: App) =
  ## Move toward the newest conversation text.
  app.scrollBy(-ScrollStep)

proc armQuit*(app: App): bool =
  ## Require a second tap to quit; returns true when quitting is confirmed.
  if epochTime() - app.quitArmedAt < QuitConfirmSeconds:
    return true
  app.quitArmedAt = epochTime()
  app.bottomDirty = true

proc clearPermission*(app: App) =
  ## Forget the displayed permission request.
  app.permission = PermissionPrompt()
  app.bottomDirty = true
