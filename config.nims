import std/[os, strutils]

# Dependencies (windy, pixie, slappy, curly, ACPort and mono-retro's touch
# keyboard) come from the enclosing Nimby workspace; see grimoire.nimble and
# nimby.lock.
switch("path", thisDir() / "src")

switch("threads", "on")
switch("define", "useCpu")
# ACPort frees some shared buffers on a different thread after the allocating
# worker has exited, which Nim's per-thread allocator cannot do; libc can.
switch("define", "useMalloc")
switch("define", "ssl")
switch("define", "windyBackends=" & getEnv("GRIMOIRE_BACKENDS", "x11"))

if getEnv("GRIMOIRE_TARGET") == "arm64":
  let cc = getEnv("GRIMOIRE_CC", "aarch64-unknown-linux-gnu-gcc")
  switch("cpu", "arm64")
  switch("gcc.exe", cc)
  switch("gcc.linkerexe", cc)
  switch("arm64.linux.gcc.exe", cc)
  switch("arm64.linux.gcc.linkerexe", cc)
  switch("passC", "-mcpu=cortex-a55")
  # Target shared libraries copied from the device (libdrm, libevdev, libudev, OpenAL, libc).
  let targetLibs = getEnv("GRIMOIRE_TARGET_LIBS", thisDir() / "../mono-retro/build/arm64-libs")
  switch("passL", "-Wl,--dynamic-linker=/lib/ld-linux-aarch64.so.1")
  switch("passL", "-L" & targetLibs)
  switch("passL", "-Wl,-rpath-link," & targetLibs)
  # The cross compiler's stack protector reads __stack_chk_guard from the dynamic loader.
  switch("passL", targetLibs / "ld-linux-aarch64.so.1")
  # The copied libc.so is the library itself rather than glibc's linker script,
  # so the static part that provides atexit and friends is linked explicitly.
  let nonshared = staticExec(cc & " -print-file-name=libc_nonshared.a").strip()
  if nonshared.isAbsolute(): switch("passL", nonshared)
  switch("define", "release")
