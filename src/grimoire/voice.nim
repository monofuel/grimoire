import
  std/[atomics, base64, json, math, os, strformat, strutils, times],
  curly, slappy

type
  Recorder* = ref object
    ## Push-to-talk microphone capture that keeps the current turn in memory only.
    mic: Microphone
    rate*: int
    gain: float
    recording*: bool
    samples*: seq[int16]
    peakDb*: float
      ## Peak level of the most recent capture chunk, in dBFS.
    levelDb, noiseDb: float
      ## Smoothed speech level and the adaptive background level, in dBFS.
    voiceDb: float
      ## Loudest smoothed level of this turn's speech, in dBFS.
    dc: float
    dcReady: bool
    lastReport: int
    heardSpeech: bool
    lastSpeechSample: int
    endSeconds*: float
      ## Silence after speech that ends the turn.
    startedAt: float
    error*: string
    reportLevels*: bool
      ## Write a once-a-second level summary to stderr while listening.
    testInput: seq[int16]
      ## Replaces the microphone for tests: played in real time, then silence.
  VoiceJobKind = enum
    transcribeJob, speakJob, quitJob
  VoiceJob = object
    kind: VoiceJobKind
    url, model, voice: string
    payload: string
      ## WAV bytes to transcribe, or text to speak.
    generation: int
  VoiceResult* = object
    speech*: bool
      ## True for synthesized speech, false for a transcript.
    text*, error*: string
    pcm*: seq[uint8]
    rate*, channels*: int
    seconds*: float
    generation*: int

const
  CaptureRate = 44100
    ## Standard rate; the handheld's ALSA capture path rejects arbitrary rates.
  SttRate = 16000
  CaptureBufferSamples = CaptureRate div 2
  MaxRecordingSeconds* = 45.0
  SilenceDb = -90.0
  SttTimeoutSeconds = 60
  SttInstruction = "Perform ASR in English."
  SpeechMarginDb = 12.0
    ## How far above the background level counts as speech.
  DcFollow = 0.001
    ## Per-sample rate at which the DC estimate follows the input (about 7 Hz).
  VoiceRangeDb = 12.0
    ## Once someone has spoken, sound this far below their loudest level is
    ## background: room noise on a hot microphone must not hold the turn open.
  QuietestSpeechDb = -50.0
  EndOfSpeechSeconds* = 2.0
    ## Default silence after speech that ends a turn: long enough for a breath
    ## or a moment's thought.
  NoSpeechSeconds* = 8.0
  LevelSmoothing = 0.25
  SpeakChunkChars = 240
  MaxSpokenChars = 1500

var
  voiceJobs: Channel[VoiceJob]
  voiceResults: Channel[VoiceResult]
  voiceThread: Thread[void]
  voiceRunning: bool
  speechGeneration: Atomic[int]
    ## Speech jobs from an older generation are skipped after an interruption.

proc newRecorder*(gainDb: float): Recorder =
  ## Prepare a recorder; the capture device opens on the first recording.
  Recorder(rate: CaptureRate, gain: pow(10.0, gainDb / 20.0), peakDb: SilenceDb,
    levelDb: SilenceDb, noiseDb: SilenceDb, voiceDb: SilenceDb, endSeconds: EndOfSpeechSeconds)

proc seconds*(recorder: Recorder): float =
  ## Report the length of the captured audio.
  recorder.samples.len / recorder.rate

proc resample(samples: seq[int16], fromRate, toRate: int): seq[int16] =
  ## Linearly resample mono PCM; speech recognition does not need more.
  if samples.len == 0 or fromRate == toRate:
    return samples
  let count = int(int64(samples.len) * toRate div fromRate)
  result = newSeq[int16](count)
  for i in 0 ..< count:
    let
      position = i * fromRate / toRate
      index = int(position)
      fraction = position - float(index)
      a = float(samples[min(index, samples.high)])
      b = float(samples[min(index + 1, samples.high)])
    result[i] = int16(a + (b - a) * fraction)

proc useTestInput*(recorder: Recorder, wav: string) =
  ## Feed a 16-bit mono WAV file instead of the microphone, as if spoken live.
  if wav.len < 44 or wav[0 ..< 4] != "RIFF":
    raise newException(ValueError, "Test input must be a WAV file")
  proc le(at, size: int): int =
    for i in countdown(size - 1, 0): result = (result shl 8) or ord(wav[at + i])
  var offset = 12
  var rate, channels, bits: int
  while offset + 8 <= wav.len:
    let size = le(offset + 4, 4)
    if wav[offset ..< offset + 4] == "fmt ":
      channels = le(offset + 10, 2)
      rate = le(offset + 12, 4)
      bits = le(offset + 22, 2)
    elif wav[offset ..< offset + 4] == "data":
      if channels != 1 or bits != 16:
        raise newException(ValueError, "Test input must be 16-bit mono")
      var samples = newSeq[int16](min(size, wav.len - offset - 8) div 2)
      for i in 0 ..< samples.len:
        samples[i] = cast[int16](uint16(le(offset + 8 + i * 2, 2)))
      recorder.testInput = resample(samples, rate, CaptureRate)
      return
    offset += 8 + size + (size and 1)
  raise newException(ValueError, "Test input has no audio data")

proc start*(recorder: Recorder) =
  ## Begin a new capture, discarding any earlier unsent audio.
  if recorder.testInput.len > 0:
    recorder.samples.setLen(0)
    recorder.error = ""
    recorder.peakDb = SilenceDb
    recorder.levelDb = SilenceDb
    recorder.noiseDb = SilenceDb
    recorder.heardSpeech = false
    recorder.voiceDb = SilenceDb
    recorder.lastReport = 0
    recorder.dcReady = false
    recorder.recording = true
    recorder.startedAt = epochTime()
    return
  if recorder.mic == nil:
    recorder.mic = newMicrophone(frequency = CaptureRate, channels = 1, bits = 16,
      bufferSize = CaptureBufferSamples)
  recorder.samples.setLen(0)
  recorder.error = ""
  recorder.peakDb = SilenceDb
  recorder.levelDb = SilenceDb
  recorder.noiseDb = SilenceDb
  recorder.heardSpeech = false
  recorder.voiceDb = SilenceDb
  recorder.lastReport = 0
  recorder.dcReady = false
  recorder.mic.start()
  recorder.recording = true
  recorder.startedAt = epochTime()

proc feed*(recorder: Recorder, chunk: openArray[int16]) =
  ## Append gain-adjusted samples, updating the level meter and speech detection.
  ## Levels are measured without the microphone's DC offset, which a high
  ## capture gain otherwise turns into a constant loud "background".
  var
    peak = 0.0
    energy = 0.0
    signal = false
  for value in chunk:
    recorder.samples.add value
    if value != 0: signal = true
  if not signal:
    # Capture start-up delivers digital silence; it says nothing about the room.
    return
  if not recorder.dcReady:
    var total = 0.0
    for value in chunk: total += float(value)
    recorder.dc = total / float(chunk.len)
    recorder.dcReady = true
  for value in chunk:
    recorder.dc += (float(value) - recorder.dc) * DcFollow
    let ac = float(value) - recorder.dc
    peak = max(peak, abs(ac))
    energy += ac * ac
  recorder.peakDb = if peak < 1: SilenceDb else: 20.0 * log10(peak / 32768.0)
  block:
    let rms = sqrt(energy / float(chunk.len))
    let chunkDb = if rms < 1: SilenceDb else: 20.0 * log10(rms / 32768.0)
    recorder.levelDb = if recorder.levelDb <= SilenceDb: chunkDb
      else: recorder.levelDb + (chunkDb - recorder.levelDb) * LevelSmoothing
    # The background estimate starts from the first real audio, follows quiet
    # passages down at once and drifts up slowly, so steady room noise is
    # learned without speech raising it.
    recorder.noiseDb = if recorder.noiseDb <= SilenceDb: recorder.levelDb
      else: min(recorder.noiseDb + 0.02, recorder.levelDb)
    var threshold = max(recorder.noiseDb + SpeechMarginDb, QuietestSpeechDb)
    if recorder.heardSpeech:
      threshold = max(threshold, recorder.voiceDb - VoiceRangeDb)
    if recorder.levelDb > threshold:
      recorder.heardSpeech = true
      recorder.voiceDb = max(recorder.voiceDb, recorder.levelDb)
      recorder.lastSpeechSample = recorder.samples.len
    if recorder.reportLevels and recorder.samples.len - recorder.lastReport >= CaptureRate:
      recorder.lastReport = recorder.samples.len
      let dcDb = 20.0 * log10(max(abs(recorder.dc), 1.0) / 32768.0)
      stderr.writeLine &"listen {recorder.seconds:.1f}s level={recorder.levelDb:.0f} dc={dcDb:.0f} " &
        &"background={recorder.noiseDb:.0f} voice={recorder.voiceDb:.0f} " &
        &"threshold={threshold:.0f} quiet={(recorder.samples.len - recorder.lastSpeechSample) / recorder.rate:.1f}s"

proc poll*(recorder: Recorder): bool =
  ## Drain captured samples and update the level; returns true when new audio arrived.
  if not recorder.recording:
    return
  if recorder.testInput.len > 0:
    let due = int((epochTime() - recorder.startedAt) * CaptureRate)
    var chunk: seq[int16]
    for i in recorder.samples.len ..< due:
      chunk.add(if i < recorder.testInput.len: recorder.testInput[i]
        else: int16((i * 7919) mod 41 - 20))
    if chunk.len == 0: return
    recorder.feed(chunk)
    return true
  let available = recorder.mic.samplesAvailable()
  if available <= 0:
    return
  let bytes = recorder.mic.read(available)
  var chunk = newSeq[int16](bytes.len div 2)
  for i in 0 ..< chunk.len:
    let raw = int(cast[int16](uint16(bytes[i * 2]) or (uint16(bytes[i * 2 + 1]) shl 8)))
    chunk[i] = int16(clamp(int(float(raw) * recorder.gain), -32768, 32767))
  recorder.feed(chunk)
  result = true

proc speechEnded*(recorder: Recorder): bool =
  ## Report that the speaker has paused long enough after talking to end the turn.
  recorder.recording and recorder.heardSpeech and
    (recorder.samples.len - recorder.lastSpeechSample) / recorder.rate >= recorder.endSeconds

proc noSpeech*(recorder: Recorder): bool =
  ## Report that nothing resembling speech arrived after a reasonable wait.
  recorder.recording and not recorder.heardSpeech and recorder.seconds >= NoSpeechSeconds

proc stop*(recorder: Recorder) =
  ## End capture, keeping the recorded samples.
  if not recorder.recording:
    return
  discard recorder.poll()
  if recorder.mic != nil: recorder.mic.stop()
  recorder.recording = false
  recorder.peakDb = SilenceDb

proc close*(recorder: Recorder) =
  ## Release the capture device.
  if recorder.mic != nil:
    if recorder.recording: recorder.mic.stop()
    recorder.mic.close()
    recorder.mic = nil
  recorder.recording = false

proc wavBytes*(samples: seq[int16], rate: int): string =
  ## Encode mono 16-bit PCM as a complete WAV file.
  proc le32(s: var string, value: int) =
    for shift in [0, 8, 16, 24]: s.add char((value shr shift) and 0xff)
  proc le16(s: var string, value: int) =
    for shift in [0, 8]: s.add char((value shr shift) and 0xff)
  let dataBytes = samples.len * 2
  result = "RIFF"
  result.le32(36 + dataBytes)
  result.add "WAVEfmt "
  result.le32(16)
  result.le16(1)
  result.le16(1)
  result.le32(rate)
  result.le32(rate * 2)
  result.le16(2)
  result.le16(16)
  result.add "data"
  result.le32(dataBytes)
  for sample in samples: result.le16(int(cast[uint16](sample)))

proc transcribe*(url, model, wav: string): string =
  ## Send one WAV turn to an OpenAI-compatible chat-completions ASR endpoint.
  let body = %*{
    "model": model,
    "messages": [
      {"role": "system", "content": SttInstruction},
      {"role": "user", "content": [
        {"type": "input_audio", "input_audio": {"data": encode(wav), "format": "wav"}}]}]}
  let curl = newCurly()
  defer: curl.close()
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  let response = curl.post(url, headers, $body, timeout = SttTimeoutSeconds)
  if response.code != 200:
    raise newException(IOError, "Speech recognition returned HTTP " & $response.code &
      ": " & response.body[0 ..< min(200, response.body.len)])
  parseJson(response.body)["choices"][0]["message"]["content"].getStr()

proc synthesize*(url, model, voice, text: string): (seq[uint8], int, int) =
  ## Speak text through an OpenAI-compatible speech endpoint, returning PCM,
  ## sample rate and channel count.
  let body = %*{"model": model, "input": text, "voice": voice, "response_format": "wav"}
  let curl = newCurly()
  defer: curl.close()
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  let response = curl.post(url, headers, $body, timeout = SttTimeoutSeconds)
  if response.code != 200:
    raise newException(IOError, "Speech synthesis returned HTTP " & $response.code &
      ": " & response.body[0 ..< min(200, response.body.len)])
  let wav = response.body
  if wav.len < 12 or wav[0 ..< 4] != "RIFF" or wav[8 ..< 12] != "WAVE":
    raise newException(IOError, "Speech synthesis did not return a WAV file")
  proc le(at, size: int): int =
    for i in countdown(size - 1, 0): result = (result shl 8) or ord(wav[at + i])
  var
    offset = 12
    channels, rate, bits: int
  while offset + 8 <= wav.len:
    let
      id = wav[offset ..< offset + 4]
      size = le(offset + 4, 4)
      body = offset + 8
    if id == "fmt ":
      channels = le(body + 2, 2)
      rate = le(body + 4, 4)
      bits = le(body + 14, 2)
    elif id == "data":
      if bits != 16 or channels notin 1 .. 2:
        raise newException(IOError, "Unsupported synthesized audio format")
      let stop = min(wav.len, body + size)
      var pcm = newSeq[uint8](stop - body)
      if pcm.len > 0: copyMem(addr pcm[0], unsafeAddr wav[body], pcm.len)
      return (pcm, rate, channels)
    offset = body + size + (size and 1)
  raise newException(IOError, "Synthesized WAV has no audio data")

proc voiceWorker() {.thread.} =
  ## Run blocking recognition and synthesis requests off the UI thread.
  while true:
    let job = voiceJobs.recv()
    case job.kind
    of quitJob: break
    of transcribeJob:
      let started = epochTime()
      var outcome = VoiceResult(generation: job.generation)
      try:
        outcome.text = transcribe(job.url, job.model, job.payload)
      except CatchableError as error:
        outcome.error = error.msg
      outcome.seconds = epochTime() - started
      voiceResults.send(outcome)
    of speakJob:
      if job.generation != speechGeneration.load():
        continue
      let started = epochTime()
      var outcome = VoiceResult(speech: true, text: job.payload, generation: job.generation)
      try:
        (outcome.pcm, outcome.rate, outcome.channels) =
          synthesize(job.url, job.model, job.voice, job.payload)
      except CatchableError as error:
        outcome.error = error.msg
      outcome.seconds = epochTime() - started
      voiceResults.send(outcome)

proc startVoiceWorker*() =
  ## Start the background speech thread.
  voiceJobs.open()
  voiceResults.open()
  createThread(voiceThread, voiceWorker)
  voiceRunning = true

proc stopVoiceWorker*() =
  ## Stop the speech thread after any request in progress.
  if not voiceRunning:
    return
  discard speechGeneration.fetchAdd(1)
  voiceJobs.send(VoiceJob(kind: quitJob))
  joinThread(voiceThread)
  voiceJobs.close()
  voiceResults.close()
  voiceRunning = false

proc submit*(recorder: Recorder, url, model: string) =
  ## Queue the recorded turn for recognition at 16 kHz.
  voiceJobs.send(VoiceJob(kind: transcribeJob, url: url, model: model,
    payload: wavBytes(resample(recorder.samples, recorder.rate, SttRate), SttRate)))

proc speakableChunks*(markdown: string): seq[string] =
  ## Turn a Markdown reply into sentence groups worth reading aloud, leaving
  ## code blocks and links on screen.
  var text = ""
  var inCode = false
  for line in markdown.splitLines():
    if line.strip().startsWith("```"):
      if not inCode: text.add " There is code on screen. "
      inCode = not inCode
      continue
    if inCode: continue
    var cleaned = line.multiReplace(("`", ""), ("**", ""), ("__", ""), ("#", ""),
      ("|", " "), ("> ", ""))
    var words: seq[string]
    for word in cleaned.splitWhitespace():
      if word.startsWith("http://") or word.startsWith("https://"): words.add "a link"
      elif word in ["-", "*"]: discard
      else: words.add word
    if words.len > 0: text.add words.join(" ") & " "
  text = text.strip()
  if text.len > MaxSpokenChars:
    var cut = text.rfind(". ", last = MaxSpokenChars)
    if cut < MaxSpokenChars div 2: cut = MaxSpokenChars
    text = text[0 .. cut] & " The rest is on screen."
  var current = ""
  var i = 0
  while i < text.len:
    current.add text[i]
    let boundary = text[i] in {'.', '!', '?', ';', ':'} and
      (i + 1 == text.len or text[i + 1] == ' ')
    if boundary and current.len >= SpeakChunkChars div 3 or current.len >= SpeakChunkChars and text[i] == ' ':
      if current.strip().len > 0: result.add current.strip()
      current = ""
    inc i
  if current.strip().len > 0: result.add current.strip()

proc speak*(text, url, model, voice: string): int =
  ## Queue a reply for synthesis, one sentence group at a time, returning the
  ## number of speech results to expect.
  let generation = speechGeneration.load()
  for chunk in speakableChunks(text):
    voiceJobs.send(VoiceJob(kind: speakJob, url: url, model: model, voice: voice,
      payload: chunk, generation: generation))
    inc result

proc interruptSpeech*() =
  ## Drop speech that is queued or still being synthesized.
  discard speechGeneration.fetchAdd(1)

proc currentSpeech*(): int =
  ## Return the generation that new speech results must match to be played.
  speechGeneration.load()

proc tryResult*(): (bool, VoiceResult) =
  ## Return a finished recognition or synthesis result if one is waiting.
  let received = voiceResults.tryRecv()
  (received.dataAvailable, received.msg)

proc saveWav*(recorder: Recorder, path: string) =
  ## Write the current capture for diagnostics.
  createDir(path.parentDir())
  writeFile(path, wavBytes(recorder.samples, recorder.rate))

type
  Speaker* = ref object
    ## Plays synthesized replies through the default audio output.
    started: bool
    source: StreamingSource
    rate, channels: int
    error*: string

proc play*(speaker: Speaker, pcm: seq[uint8], rate, channels: int) =
  ## Append synthesized PCM to the reply being spoken.
  if speaker.error.len > 0 or pcm.len == 0:
    return
  try:
    if not speaker.started:
      slappyInit()
      speaker.started = true
    if speaker.source == nil or speaker.rate != rate or speaker.channels != channels:
      if speaker.source != nil: speaker.source.close()
      speaker.source = newStreamingSource(rate, channels, 16)
      speaker.rate = rate
      speaker.channels = channels
    speaker.source.queueData(pcm)
  except CatchableError as error:
    speaker.error = error.msg

proc speaking*(speaker: Speaker): bool =
  ## Report whether reply audio is still queued or playing.
  if speaker.source == nil:
    return false
  speaker.source.pump()
  speaker.source.queuedLen > 0

proc silence*(speaker: Speaker) =
  ## Stop the reply immediately and discard queued audio.
  if speaker.source != nil: speaker.source.flush()

proc close*(speaker: Speaker) =
  ## Release the audio output.
  if speaker.source != nil:
    speaker.source.close()
    speaker.source = nil
  if speaker.started:
    try: slappyClose() except CatchableError: discard
    speaker.started = false
