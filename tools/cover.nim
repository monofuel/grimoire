## Draw Grimoire's launcher cover art: a spellbook whose sigil is a sound wave.
## Run `nim r tools/cover.nim` to write assets/cover.png.

import
  std/[math, os, random],
  pixie

const
  Width = 480
  Height = 640
  Gold = parseHtmlColor("#e8c46a")
  Glow = parseHtmlColor("#7fd8ff")

proc goldPaint(alpha = 1.0'f32): Paint =
  ## Solid gold with the given opacity.
  result = newPaint(SolidPaint)
  result.color = Gold
  result.opacity = alpha

proc background(image: Image) =
  ## Night-sky gradient with faint stars.
  let paint = newPaint(LinearGradientPaint)
  paint.gradientHandlePositions = @[vec2(0, 0), vec2(0, Height.float32)]
  paint.gradientStops = @[
    ColorStop(color: parseHtmlColor("#1a1036"), position: 0),
    ColorStop(color: parseHtmlColor("#0a0d1c"), position: 1)]
  image.fillPath((block:
    let path = newPath()
    path.rect(0, 0, Width.float32, Height.float32)
    path), paint)
  var rng = initRand(11)
  let ctx = newContext(image)
  for i in 0 ..< 70:
    let
      x = rng.rand(Width.float32)
      y = rng.rand(Height.float32)
      r = rng.rand(0.4'f32 .. 1.6'f32)
    ctx.fillStyle = rgba(255, 255, 255, uint8(rng.rand(60 .. 200)))
    ctx.fillCircle(circle(vec2(x, y), r))

proc book(image: Image) =
  ## Leather cover with a gilded frame and corner pieces.
  let ctx = newContext(image)
  let cover = rect(78, 50, 324, 540)
  let leather = newPaint(LinearGradientPaint)
  leather.gradientHandlePositions = @[vec2(cover.x, cover.y), vec2(cover.x + cover.w, cover.y + cover.h)]
  leather.gradientStops = @[
    ColorStop(color: parseHtmlColor("#5a1f2e"), position: 0),
    ColorStop(color: parseHtmlColor("#2c0d1a"), position: 1)]
  ctx.fillStyle = leather
  ctx.fillRoundedRect(cover, 14)
  # Spine shading and page edges.
  ctx.fillStyle = rgba(0, 0, 0, 90)
  ctx.fillRect(rect(cover.x, cover.y, 26, cover.h))
  ctx.fillStyle = parseHtmlColor("#e9dcc0")
  ctx.fillRect(rect(cover.x + cover.w - 4, cover.y + 10, 6, cover.h - 20))
  # Gilded frame.
  ctx.strokeStyle = goldPaint()
  ctx.lineWidth = 3
  ctx.strokeRoundedRect(rect(cover.x + 40, cover.y + 18, cover.w - 62, cover.h - 36), 8)
  ctx.lineWidth = 1.5
  ctx.strokeRoundedRect(rect(cover.x + 48, cover.y + 26, cover.w - 78, cover.h - 52), 6)
  for (cx, cy) in [(cover.x + 40, cover.y + 18), (cover.x + cover.w - 22, cover.y + 18),
      (cover.x + 40, cover.y + cover.h - 18), (cover.x + cover.w - 22, cover.y + cover.h - 18)]:
    ctx.fillStyle = goldPaint()
    ctx.fillCircle(circle(vec2(cx, cy), 7))
    ctx.fillStyle = parseHtmlColor("#2c0d1a")
    ctx.fillCircle(circle(vec2(cx, cy), 3))

proc sigil(center: Vec2, radius: float32): Image =
  ## Runic circle around a microphone-style sound wave, drawn on its own layer.
  result = newImage(Width, Height)
  let ctx = newContext(result)
  ctx.strokeStyle = Glow
  ctx.lineWidth = 3
  ctx.strokeCircle(circle(center, radius))
  ctx.lineWidth = 1.5
  ctx.strokeCircle(circle(center, radius - 12))
  # Rune ticks between the rings.
  for i in 0 ..< 24:
    let
      a = float32(i) * PI.float32 * 2 / 24
      inner = radius - 10
      outer = radius - 2
      dir = vec2(cos(a), sin(a))
    ctx.lineWidth = if i mod 3 == 0: 3 else: 1.5
    ctx.strokeSegment(segment(center + dir * inner, center + dir * outer))
  # Hexagram.
  for start in [0.0'f32, PI.float32 / 3]:
    let path = newPath()
    for k in 0 .. 3:
      let a = start + float32(k) * PI.float32 * 2 / 3 - PI.float32 / 2
      let point = center + vec2(cos(a), sin(a)) * (radius - 16)
      if k == 0: path.moveTo(point) else: path.lineTo(point)
    ctx.lineWidth = 1.2
    ctx.stroke(path)
  # Sound wave bars through the middle.
  let heights = [10.0'f32, 20, 34, 50, 66, 50, 34, 20, 10]
  for i, h in heights:
    let x = center.x + (float32(i) - 4) * 12
    ctx.lineWidth = 7
    ctx.lineCap = RoundCap
    ctx.strokeSegment(segment(vec2(x, center.y - h / 2), vec2(x, center.y + h / 2)))

proc title(image: Image) =
  ## Gilded title on the cover.
  let typeface = readTypeface(currentSourcePath().parentDir / ".." / "assets" / "Roboto-Regular.ttf")
  let font = newFont(typeface)
  font.size = 42
  font.paint = goldPaint()
  image.fillText(font.typeset("GRIMOIRE", vec2(262, 60), CenterAlign, MiddleAlign),
    translate(vec2(118, 420)))
  font.size = 14
  font.paint = goldPaint(0.75)
  image.fillText(font.typeset("SPEAK, AND IT IS WRITTEN", vec2(262, 24), CenterAlign, MiddleAlign),
    translate(vec2(118, 482)))

proc main() =
  ## Compose and save the cover.
  let image = newImage(Width, Height)
  image.background()
  let bookLayer = newImage(Width, Height)
  bookLayer.book()
  image.draw(bookLayer.shadow(offset = vec2(0, 12), spread = 0, blur = 30,
    color = rgba(0, 0, 0, 200)))
  image.draw(bookLayer)
  let center = vec2(249, 250)
  let layer = sigil(center, 104)
  let glow = layer.copy()
  glow.blur(14)
  image.draw(glow, blendMode = ScreenBlend)
  image.draw(glow, blendMode = ScreenBlend)
  image.draw(layer)
  image.title()
  let path = currentSourcePath().parentDir / ".." / "assets" / "cover.png"
  image.writeFile(path)
  echo "wrote ", path

main()
