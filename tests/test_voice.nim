import
  std/[math, random, strutils, unittest],
  grimoire/voice

const Rate = 44100

proc noise(seconds: float, amplitude: int): seq[int16] =
  ## Make steady background noise.
  for i in 0 ..< int(seconds * Rate):
    result.add int16(rand(-amplitude .. amplitude))

proc voiced(seconds: float, amplitude: float): seq[int16] =
  ## Make a loud speech-like tone.
  for i in 0 ..< int(seconds * Rate):
    result.add int16(amplitude * sin(2 * PI * 220 * float(i) / Rate))

proc feedLive(recorder: Recorder, audio: seq[int16]): bool =
  ## Feed audio in 15 ms chunks like the UI loop; returns true if the turn ended early.
  var i = 0
  while i < audio.len:
    let stop = min(audio.len, i + Rate * 15 div 1000)
    recorder.feed(audio[i ..< stop])
    if recorder.speechEnded(): return true
    i = stop

suite "speech detection":
  setup:
    randomize(7)
    let recorder = newRecorder(0)
    recorder.recording = true

  test "a thinking pause does not end the turn, a longer one does":
    check not recorder.feedLive(noise(1.0, 300))
    check not recorder.feedLive(voiced(0.8, 8000))
    check not recorder.feedLive(noise(recorder.endSeconds - 0.4, 300))
    check not recorder.feedLive(voiced(0.8, 8000))
    check recorder.feedLive(noise(recorder.endSeconds + 1.0, 300))
    let spoken = 1.0 + 0.8 + (recorder.endSeconds - 0.4) + 0.8
    check recorder.seconds >= spoken + recorder.endSeconds
    check recorder.seconds < spoken + recorder.endSeconds + 0.4

  test "quiet speech over room noise still counts":
    check not recorder.feedLive(noise(1.0, 600))
    check not recorder.feedLive(voiced(1.0, 2500))
    check recorder.feedLive(noise(recorder.endSeconds + 1.0, 600))

  test "a noisy room on a hot microphone still ends the turn":
    proc busyRoom(seconds: float): seq[int16] =
      ## Steady hiss with short louder clatters, like a fan and a keyboard.
      for i in 0 ..< int(seconds * Rate):
        let burst = (i div (Rate div 10)) mod 7 == 0
        result.add int16(rand(-1 .. 1) * (if burst: 1800 else: 1000))
    check not recorder.feedLive(busyRoom(1.0))
    check not recorder.feedLive(voiced(1.5, 12000))
    check recorder.feedLive(busyRoom(recorder.endSeconds + 2.0))
    check recorder.seconds < 1.0 + 1.5 + recorder.endSeconds + 0.6

  test "a microphone DC offset does not hold the turn open":
    proc offset(audio: seq[int16]): seq[int16] =
      for value in audio: result.add int16(int(value) + 1500)
    check not recorder.feedLive(offset(noise(1.0, 300)))
    check not recorder.feedLive(offset(voiced(1.0, 3000)))
    check recorder.feedLive(offset(noise(recorder.endSeconds + 1.0, 300)))

  test "start-up digital silence does not set the background":
    check not recorder.feedLive(newSeq[int16](Rate div 5))
    check not recorder.feedLive(noise(1.0, 3000))
    check recorder.feedLive(voiced(1.0, 20000) & noise(recorder.endSeconds + 1.0, 3000))

  test "room noise alone is not speech":
    check not recorder.feedLive(noise(NoSpeechSeconds + 0.5, 600))
    check recorder.noSpeech()

suite "spoken replies":
  test "code blocks and links stay on screen":
    let chunks = speakableChunks("Done. See `app.nim`:\n```nim\necho 1\n```\nDocs at https://example.com/x.")
    let spoken = chunks.join(" ")
    check "echo" notin spoken
    check "code on screen" in spoken
    check "a link" in spoken
    check "`" notin spoken

  test "long replies are split and capped":
    var reply = ""
    for i in 0 ..< 200: reply.add "This is sentence number " & $i & ". "
    let chunks = speakableChunks(reply)
    check chunks.len > 3
    for chunk in chunks: check chunk.len <= 300
    check chunks[^1].endsWith("The rest is on screen.")
