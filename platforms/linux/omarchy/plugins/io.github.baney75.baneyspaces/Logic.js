// Pure helpers for the BaneySpaces shell plugin: no Quickshell, no QML types, so `node` runs the
// tests in platforms/linux/tests/logic.test.js against this very file.
.pragma library

// colors.toml: `key = "#rrggbb"` lines. Returns { key: "#rrggbb" }.
function parseColors(text) {
  var out = {}
  String(text || "").split("\n").forEach(function (line) {
    var m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*"(#[0-9A-Fa-f]{3,8})"\s*(#.*)?$/)
    if (m) out[m[1]] = m[2].toLowerCase()
    var md = line.match(/^\s*mode\s*=\s*"(dark|light)"/)
    if (md) out.mode = md[1]
  })
  return out
}

function hex(value, fallback) {
  return /^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(value || "") ? value : fallback
}

function _rgb(h) {
  return [parseInt(h.substr(1, 2), 16), parseInt(h.substr(3, 2), 16), parseInt(h.substr(5, 2), 16)]
}

function _h2(n) {
  var s = Math.round(Math.max(0, Math.min(255, n))).toString(16)
  return s.length < 2 ? "0" + s : s
}

// t of the way from a to b, both "#rrggbb".
function mix(a, b, t) {
  var x = _rgb(a), y = _rgb(b)
  return "#" + _h2(x[0] + (y[0] - x[0]) * t) + _h2(x[1] + (y[1] - x[1]) * t) + _h2(x[2] + (y[2] - x[2]) * t)
}

// "#rrggbb" with alpha 0..1 as "#aarrggbb" (what QML reads).
function alpha(h, a) {
  return "#" + _h2(a * 255) + h.substr(1, 6)
}

function luminance(h) {
  var c = _rgb(h).map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) })
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

// A color that reads on `bg`: the foreground, unless it is too close.
function readable(fg, bg) {
  var l1 = luminance(fg), l2 = luminance(bg)
  var ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
  return ratio >= 4.5 ? fg : (l2 > 0.4 ? "#101010" : "#f2f2f2")
}

// The nine workspace colors, from the theme's own palette.
function workspaceColors(c) {
  var order = ["blue", "green", "yellow", "orange", "red", "magenta", "cyan", "bright_green", "bright_magenta"]
  return order.map(function (k, i) { return hex(c[k], hex(c.accent, "#7aa2f7")) })
}

// Tile geometry in points: the theme's tile size, scaled by the dock size setting.
function tileSpecFor(tok, size) {
  var f = { small: 0.8, medium: 1, large: 1.25 }[size] || 1
  var pad = Math.max(4, Math.round(8 * f))
  // themes.json's space.tile is the width of a tile holding one icon: the icon and a pad on each side.
  var icon = Math.max(18, Math.round((tok.space.tile - 16) * f))
  var num = Math.max(9, Math.round(tok.font.size * f))
  var s = { icon: icon, pad: pad, num: num, gap: Math.max(2, Math.round(tok.space.gap * f)) }
  s.height = pad * 2 + icon + num + 8
  s.radius = tok.radius.tile
  return s
}

// Which of the rectangles [{x,y,w,h,...}] holds the point, or -1.
function pickRect(rects, x, y) {
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i]
    if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return i
  }
  return -1
}

// Where a list goes: centered over its tile, kept on screen, standing on the bar.
function listPlacement(tile, size, bounds, gap) {
  var x = tile.x + tile.w / 2 - size.w / 2
  x = Math.max(gap, Math.min(bounds.w - size.w - gap, x))
  return { x: Math.round(x), y: Math.round(tile.y - gap - size.h) }
}

function stepIndex(i, n, dir) {
  if (n <= 0) return 0
  return ((i + dir) % n + n) % n
}

// The window to show when an app's icon is clicked: the next one after the front window, or the first.
function nextWindow(windows, focused) {
  if (!windows || windows.length === 0) return null
  for (var i = 0; i < windows.length; i++) if (windows[i].window === focused || windows[i].focused) return windows[(i + 1) % windows.length].window
  return windows[0].window
}

// Results [{section,...}] in order -> rows with section headers, each result keeping its flat index.
function sectionRows(results) {
  var rows = [], last = null
  results.forEach(function (r, i) {
    if (r.section !== last) { rows.push({ header: r.section }); last = r.section }
    var copy = {}
    for (var k in r) copy[k] = r[k]
    copy.index = i
    rows.push(copy)
  })
  return rows
}

var MODES = ["all", "apps", "files", "install", "remove", "update", "system", "workspaces"]
var MODE_LABELS = { all: "All", apps: "Apps", files: "Files", install: "Install", remove: "Remove", update: "Update", system: "System", workspaces: "Workspaces" }

function nextMode(mode, dir, enabled) {
  var list = MODES.filter(function (m) { return enabled[m] !== false })
  var i = list.indexOf(mode)
  return list[stepIndex(i < 0 ? 0 : i, list.length, dir)]
}

function badgeGlyph(state, count) {
  if (state === "asking") return "?"
  if (state === "error") return "!"
  if (state === "finished") return count > 1 ? String(count) : "•"
  return ""
}

// "+N" label for the apps a tile cannot show.
function moreLabel(n) { return n > 0 ? "+" + n : "" }

// Short label for a window row: its title, or its app when the title is empty.
function rowTitle(w) { return w.title && w.title.length ? w.title : (w.app || "") }

// Overview grid: where card i of nine goes in a w x h area (3 x 3, gap g).
function gridRect(i, w, h, g) {
  var cw = (w - g * 4) / 3, ch = (h - g * 4) / 3
  var col = i % 3, row = Math.floor(i / 3)
  return { x: g + col * (cw + g), y: g + row * (ch + g), w: cw, h: ch }
}

// Arrow keys on the 3 x 3 grid (0-based index), without wrapping off an edge.
function gridMove(i, key) {
  var col = i % 3, row = Math.floor(i / 3)
  if (key === "left" && col > 0) return i - 1
  if (key === "right" && col < 2) return i + 1
  if (key === "up" && row > 0) return i - 3
  if (key === "down" && row < 2) return i + 3
  return i
}

// ---- themes (spec/themes.md): shape, type and motion from themes.json; color from a palette -------------

// BaneySpaces role -> Omarchy colors.toml keys in order of preference (scripts/gen-palettes.py's table).
var ROLE_KEYS = {
  background: ["background"], surface: ["lighter_background", "background"], sunken: ["dark_background", "background"],
  foreground: ["foreground"], strong: ["bright_foreground", "light_foreground", "foreground"],
  muted: ["dark_foreground", "muted"], border: ["muted", "dark_foreground"], accent: ["accent", "blue"],
  selection: ["selection", "lighter_background"], urgent: ["red"], working: ["yellow"], done: ["green"]
}

// The live Omarchy theme's colors.toml as palette roles, or null if it lacks a color a role needs.
function paletteFromColors(c) {
  var out = { mode: c.mode || "dark" }
  for (var role in ROLE_KEYS) {
    var keys = ROLE_KEYS[role], v = null
    for (var i = 0; i < keys.length && v === null; i++) if (/^#[0-9a-f]{6}$/i.test(c[keys[i]] || "")) v = c[keys[i]].toLowerCase()
    if (v === null) return null
    out[role] = v
  }
  return out
}

// The nine workspace tints, all from the palette.
function tintsOf(p) {
  return [p.accent, p.done, p.working, p.urgent, mix(p.accent, p.urgent, 0.5), mix(p.done, p.accent, 0.5),
    mix(p.working, p.urgent, 0.5), mix(p.urgent, p.accent, 0.25), mix(p.accent, p.strong, 0.5)]
}

// A role name from themes.json as a color. `light` is white; `workspace` is the workspace's own tint.
function roleColor(p, role, tint) {
  if (role === "light") return "#ffffff"
  if (role === "workspace") return tint || p.accent
  return p[role] || p.accent
}

// A copy of `base` with the tokens of `over` laid on top (the config's [theme.override]).
function deepMerge(base, over) {
  if (over === null || typeof over !== "object" || Array.isArray(over)) return over === undefined ? base : over
  var out = {}
  for (var k in base) out[k] = base[k]
  for (var j in over) out[j] = (base && typeof base[j] === "object" && base[j] !== null && !Array.isArray(base[j])) ? deepMerge(base[j], over[j]) : over[j]
  return out
}

// The durations a surface runs, from the theme's motion tokens, the animation preset and speed, your own per-surface times and
// reduced motion (spec/config.md). `cfg`: { preset, speed, dock_in_ms, dock_out_ms, list_in_ms, list_out_ms, row_ms } (-1: use the preset).
function motionFor(m, cfg, reduce) {
  cfg = cfg || {}
  var preset = cfg.preset || "baneyspaces", speed = cfg.speed === undefined ? 1 : cfg.speed
  var base = { dockIn: m.in_ms, dockOut: m.out_ms, listIn: m.list_in_ms, listOut: m.list_out_ms, row: m.row_ms, listFrom: m.scale_from, lift: m.lift, slide: m.scale_from < 1 ? 8 : 0 }
  var factor = 1
  if (preset === "omarchy") base = { dockIn: 410, dockOut: 149, listIn: 400, listOut: 150, row: 0, listFrom: 0.87, lift: 1, slide: 0 }
  else if (preset === "snappy") factor = 0.6
  else if (preset === "smooth") factor = 1.3
  else if (preset === "off") factor = 0
  var out = { listFrom: base.listFrom, lift: base.lift, slide: base.slide }
  var mine = { dockIn: cfg.dock_in_ms, dockOut: cfg.dock_out_ms, listIn: cfg.list_in_ms, listOut: cfg.list_out_ms, row: cfg.row_ms }
  for (var k in mine) {
    var ms = mine[k] !== undefined && mine[k] >= 0 ? mine[k] : base[k] * factor
    out[k] = Math.round(ms * speed)
  }
  if (reduce || preset === "off" || speed === 0) { out.dockIn = out.dockOut = out.listIn = out.listOut = out.row = 0; out.listFrom = 1; out.lift = 1; out.slide = 0 }
  return out
}

// Everything a surface needs, resolved. `o`: { theme, palette, auto (colors.toml parsed), opacity, reduce, scaling }.
function resolveTheme(spec, o) {
  var t = deepMerge(spec.themes[o.theme] || spec.themes.omarchy, o.override || {})
  var name = spec.themes[o.theme] ? o.theme : "omarchy"
  var pal = null, palName = o.palette || "auto"
  if (palName === "auto") pal = o.auto ? paletteFromColors(o.auto) : null
  else pal = spec.palettes.palettes[palName] || null
  if (!pal) { palName = "tokyo-night"; pal = spec.palettes.palettes["tokyo-night"] }
  var tints = tintsOf(pal)
  var b = t.border, f = t.fill
  var gradient = b.gradient ? { top: b.gradient[0], bottom: b.gradient[1] } : null
  var fillOpacity = f.adjustable && o.opacity !== undefined && o.opacity !== null ? o.opacity : f.opacity
  var tint = roleColor(pal, f.tint_role, null)
  // With a material the platform blurs what is behind; here the compositor may, and the tint sits on the background.
  var base = f.material ? mix(pal.background, tint, f.tint_opacity) : mix(pal.background, tint, f.tint_opacity)
  if (!f.material) base = roleColor(pal, f.tint_role, null)
  var m = t.motion
  var scaling = m.scale_from < 1
  var motion = motionFor(m, o.motion, o.reduce)
  var fams = (spec.fonts[t.font.family] || {}).linux || ["sans-serif"]
  return {
    theme: name, palette: palName, mode: pal.mode, roles: pal, tints: tints,
    radius: { bar: t.radius.bar, tile: t.radius.tile, row: t.radius.row, list: t.radius.list },
    border: {
      width: b.width, color: roleColor(pal, b.role, null), opacity: b.opacity === undefined ? null : b.opacity, gradient: gradient,
      focusedWidth: b.focused_width, focusedRole: b.focused_role,
      focusedColor: b.focused_role === "workspace" ? null : roleColor(pal, b.focused_role, null)
    },
    fill: { material: f.material, tintRole: f.tint_role, tintOpacity: f.tint_opacity, opacity: fillOpacity, adjustable: f.adjustable, color: base, solid: !f.material && fillOpacity >= 1 },
    shadow: t.shadow,
    font: { families: fams, size: t.font.size, weight: t.font.weight },
    space: t.space, indicator: t.indicator, motion: motion, scaling: scaling
  }
}

// A border color with an opacity as "#aarrggbb".
function withOpacity(hexColor, a) { return alpha(hexColor, a === null || a === undefined ? 1 : a) }

if (typeof module !== "undefined") {
  module.exports = { parseColors: parseColors, hex: hex, mix: mix, alpha: alpha, luminance: luminance, readable: readable,
    workspaceColors: workspaceColors, tileSpecFor: tileSpecFor, pickRect: pickRect, listPlacement: listPlacement,
    stepIndex: stepIndex, nextWindow: nextWindow, sectionRows: sectionRows, nextMode: nextMode, badgeGlyph: badgeGlyph,
    moreLabel: moreLabel, ROLE_KEYS: ROLE_KEYS, paletteFromColors: paletteFromColors, tintsOf: tintsOf, roleColor: roleColor, resolveTheme: resolveTheme, motionFor: motionFor, deepMerge: deepMerge, withOpacity: withOpacity, rowTitle: rowTitle, gridRect: gridRect, gridMove: gridMove, MODES: MODES }
}
