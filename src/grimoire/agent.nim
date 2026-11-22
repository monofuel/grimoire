import
  std/[json, options, os, strutils],
  acport

type
  AgentState* = enum
    disconnected, connecting, idle, working, cancelling, failed
  EventKind* = enum
    agentText, thought, toolStarted, toolChanged, planChanged, permissionAsked, agentLog
  AgentEvent* = object
    kind*: EventKind
    text*, toolId*, status*: string
    options*: seq[(string, string)]
      ## Permission option ids paired with their labels.
  PermissionReply = object
    optionId: string
  Agent* = ref object
    ## One ACP connection and session for the selected project.
    client: AcpClient
    session: AcpSession
    handle: PromptHandle
    prompting: bool
    state*: AgentState
    name*, model*, mode*, error*: string
    instructions*: string
      ## Appended to the agent's own system prompt for each new session.
    sessionMeta*: JsonNode
      ## Agent-specific `_meta` for each new session, or nil.
    modes*: seq[(string, string)]
      ## The session's permission modes as (id, display name).
    permissionPending*: bool

const
  ClientName = "grimoire"
  ClientVersion = "0.1.0"
  ConnectTimeoutMs = 60_000
  PermissionPollMs = 25
  MaxToolDetail = 600

var
  events: Channel[AgentEvent]
  replies: Channel[PermissionReply]

proc toolDetail(tool: ToolCall): string =
  ## Summarize a tool call's input for a human decision.
  if tool.rawInput != nil and tool.rawInput.kind != JNull:
    result = $tool.rawInput
    if result.len > MaxToolDetail: result = result[0 ..< MaxToolDetail] & "…"

proc onUpdate(update: SessionUpdate, userData: pointer) {.gcsafe.} =
  ## Forward streamed session updates to the UI thread.
  {.cast(gcsafe).}:
    case update.kind
    of agentMessageChunk:
      if update.content.kind == textContent:
        events.send(AgentEvent(kind: agentText, text: update.content.text))
    of agentThoughtChunk:
      if update.content.kind == textContent:
        events.send(AgentEvent(kind: thought, text: update.content.text))
    of toolCall:
      events.send(AgentEvent(kind: toolStarted, toolId: update.tool.toolCallId,
        text: update.tool.title, status: update.tool.status))
    of toolCallUpdate:
      events.send(AgentEvent(kind: toolChanged, toolId: update.tool.toolCallId,
        text: update.tool.title, status: update.tool.status))
    of planUpdate:
      var lines: seq[string]
      for entry in update.entries:
        lines.add "[" & entry.status & "] " & entry.content
      events.send(AgentEvent(kind: planChanged, text: lines.join("\n")))
    else: discard

proc onPermission(context: RequestContext, request: PermissionRequest,
    userData: pointer): PermissionOutcome {.gcsafe.} =
  ## Block the agent's request until a person taps an option on the touch screen.
  {.cast(gcsafe).}:
    # Discard a late answer to an earlier request that was already cancelled.
    while replies.tryRecv().dataAvailable: discard
    var event = AgentEvent(kind: permissionAsked, toolId: request.toolCall.toolCallId,
      text: request.toolCall.title, status: toolDetail(request.toolCall))
    for option in request.options:
      event.options.add (option.optionId, option.name)
    events.send(event)
    result = PermissionOutcome(outcome: "cancelled")
    while not context.isCancelled():
      let reply = replies.tryRecv()
      if reply.dataAvailable:
        if reply.msg.optionId.len > 0:
          result = PermissionOutcome(outcome: "selected", optionId: reply.msg.optionId)
        break
      sleep(PermissionPollMs)

proc onLog(userData: pointer, text: string) {.gcsafe.} =
  ## Keep agent stderr visible without mixing it into the conversation.
  {.cast(gcsafe).}:
    events.send(AgentEvent(kind: agentLog, text: text))

proc initAgentChannels*() =
  ## Open the cross-thread queues used by ACP callbacks.
  events.open()
  replies.open()

proc nextEvent*(): (bool, AgentEvent) =
  ## Return a queued agent event if one is waiting.
  let received = events.tryRecv()
  (received.dataAvailable, received.msg)

proc answerPermission*(agent: Agent, optionId: string) =
  ## Deliver a person's choice; an empty id cancels the request.
  agent.permissionPending = false
  replies.send(PermissionReply(optionId: optionId))

proc modelLabel(session: AcpSession): string =
  ## Describe the session's current model selector, when the agent exposes one.
  for option in session.getConfigOptions():
    if option.id == "model" or option.category == some("model"):
      let current = option.raw{"currentValue"}
      if current != nil: return current.getStr($current)

proc describeSession*(agent: Agent): string =
  ## Summarize the session's modes and configuration options for diagnostics.
  let modes = agent.session.getModes()
  if modes.isSome:
    result.add "mode=" & modes.get().currentModeId
  for option in agent.session.getConfigOptions():
    result.add " " & option.id & "=" & $option.raw{"currentValue"}

proc close*(agent: Agent) =
  ## Stop the agent process and its connection threads.
  if agent.client != nil:
    if agent.permissionPending: agent.answerPermission("")
    agent.client.close()
    agent.client = nil
  agent.prompting = false
  agent.state = disconnected

proc openSession(agent: Agent, cwd, mode: string) =
  ## Create a session in cwd on the connected agent and select its mode.
  let prompt = if agent.instructions.len == 0: none(SystemPrompt)
    else: some(SystemPrompt(mode: "append", content: @[textBlock(agent.instructions)]))
  agent.session = agent.client.newSession(cwd, timeoutMs = ConnectTimeoutMs,
    meta = agent.sessionMeta, systemPrompt = prompt)
  if mode.len > 0:
    agent.session.setMode(mode, ConnectTimeoutMs)
  let modes = agent.session.getModes()
  agent.mode = if mode.len > 0: mode
    elif modes.isSome: modes.get().currentModeId else: ""
  agent.modes.setLen(0)
  if modes.isSome:
    for available in modes.get().availableModes:
      agent.modes.add (available.id, available.name)
  agent.model = modelLabel(agent.session)
  agent.state = idle

proc modeName*(agent: Agent): string =
  ## Return the display name of the current permission mode.
  result = agent.mode
  for (id, name) in agent.modes:
    if id == agent.mode and name.len > 0: return name

proc nextMode*(agent: Agent): string =
  ## Switch the session to the following permission mode, returning its id.
  if agent.modes.len == 0:
    return agent.mode
  var index = 0
  for i, (id, _) in agent.modes:
    if id == agent.mode: index = (i + 1) mod agent.modes.len
  let id = agent.modes[index][0]
  agent.session.setMode(id, ConnectTimeoutMs)
  agent.mode = id
  id

proc fail(agent: Agent, error: ref CatchableError) =
  ## Record a connection failure and release the client.
  agent.error = error.msg
  agent.state = failed
  if agent.client != nil:
    try: agent.client.close() except CatchableError: discard
    agent.client = nil

proc connect*(agent: Agent, command: seq[string], cwd: string, mode = "") =
  ## Launch the configured ACP command and open a session in cwd on the agent's host.
  ## A non-empty mode selects the agent's permission mode, such as Claude's "default".
  agent.close()
  agent.error = ""
  agent.state = connecting
  if command.len == 0 or (command[0].isAbsolute() and not fileExists(command[0])):
    agent.state = failed
    agent.error = "no ACP agent command is available on this machine. " &
      "Start Grimoire from the development host (make run-rg-ds-plus) or set \"agent\" in the config."
    return
  try:
    agent.client = newAcpClient(ClientName, ClientVersion,
      ClientHandlers(onUpdate: onUpdate, onPermission: onPermission, onLog: onLog))
    agent.client.connect(command[0], command[1 .. ^1])
    let info = agent.client.initialize(ConnectTimeoutMs)
    agent.name = if info.agentInfo.isSome: info.agentInfo.get().name else: "agent"
    agent.openSession(cwd, mode)
  except CatchableError as error:
    agent.fail(error)

proc canSwitch*(agent: Agent): bool =
  ## Report whether a new session can reuse the current connection.
  agent.client != nil and agent.state == idle

proc switchSession*(agent: Agent, cwd: string, mode = "") =
  ## Start a fresh session in another directory over the existing connection.
  agent.error = ""
  agent.state = connecting
  try:
    agent.openSession(cwd, mode)
  except CatchableError as error:
    agent.fail(error)

proc send*(agent: Agent, text: string) =
  ## Start a prompt turn; progress arrives through nextEvent.
  if agent.state != idle:
    raise newException(ValueError, "Agent is not ready for a prompt")
  agent.handle = agent.session.startPrompt(@[textBlock(text)])
  agent.prompting = true
  agent.state = working

proc cancel*(agent: Agent) =
  ## Ask the agent to stop the current turn; pending permission is cancelled too.
  if agent.state != working:
    return
  if agent.permissionPending: agent.answerPermission("")
  agent.session.cancel()
  agent.state = cancelling

proc poll*(agent: Agent): string =
  ## Finish a completed turn, returning its stop reason or an empty string.
  if not agent.prompting or not agent.handle.isReady():
    return
  agent.prompting = false
  try:
    let response = waitForPrompt(agent.handle)
    result = $response.stopReason
    agent.state = idle
  except CatchableError as error:
    agent.error = error.msg
    agent.state = failed
    result = "error"
