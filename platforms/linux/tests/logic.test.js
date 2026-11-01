// Unit tests for the shell plugin's pure helpers (Logic.js). Run: node --test platforms/linux/tests/logic.test.js
// Logic.js starts with `.pragma library`, which QML wants and JavaScript does not: it is stripped here.
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const file = path.join(__dirname, "../omarchy/plugins/io.github.baney75.baneyspaces/Logic.js");
const src = fs.readFileSync(file, "utf8").replace(/^\.pragma library\s*$/m, "");
const mod = { exports: {} };
new Function("module", src)(mod);
const L = mod.exports;
const specDir = path.join(__dirname, "../../../spec");
const spec = { themes: JSON.parse(fs.readFileSync(path.join(specDir, "themes.json"), "utf8")).themes, fonts: JSON.parse(fs.readFileSync(path.join(specDir, "themes.json"), "utf8")).fonts, palettes: JSON.parse(fs.readFileSync(path.join(specDir, "palettes.json"), "utf8")) };


test("colors.toml of a stock theme parses", () => {
  const f = "/usr/share/omarchy/themes/tokyo-night/colors.toml";
  const text = fs.existsSync(f) ? fs.readFileSync(f, "utf8") : 'accent = "#7aa2f7"\nbackground = "#1a1b26"\nmode = "dark"\n';
  const c = L.parseColors(text);
  assert.strictEqual(c.accent, "#7aa2f7");
  assert.strictEqual(c.background, "#1a1b26");
  assert.strictEqual(c.mode, "dark", "the mode is kept, other words are not");
  assert.deepStrictEqual(L.parseColors('x = "red"\n# y = "#fff"\n z = "#ABCDEF" # note'), { z: "#abcdef" });
  assert.deepStrictEqual(L.parseColors(null), {});
});

test("hex falls back on anything that is not a color", () => {
  assert.strictEqual(L.hex("#aabbcc", "#000000"), "#aabbcc");
  assert.strictEqual(L.hex("aabbcc", "#000000"), "#000000");
  assert.strictEqual(L.hex(undefined, "#111111"), "#111111");
});

test("mix and alpha", () => {
  assert.strictEqual(L.mix("#000000", "#ffffff", 0.5), "#808080");
  assert.strictEqual(L.mix("#102030", "#102030", 0.7), "#102030");
  assert.strictEqual(L.alpha("#7aa2f7", 1), "#ff7aa2f7");
  assert.strictEqual(L.alpha("#7aa2f7", 0), "#007aa2f7");
});

test("readable keeps a foreground that reads and replaces one that does not", () => {
  assert.strictEqual(L.readable("#c0caf5", "#1a1b26"), "#c0caf5");
  assert.strictEqual(L.readable("#303030", "#1a1b26"), "#f2f2f2");
  assert.strictEqual(L.readable("#f0f0f0", "#fafafa"), "#101010");
});

test("nine workspace colors come from the theme, with the accent as the fallback", () => {
  const full = L.workspaceColors({ blue: "#0000ff", green: "#00ff00" , accent: "#123456"});
  assert.strictEqual(full.length, 9);
  assert.strictEqual(full[0], "#0000ff");
  assert.strictEqual(full[2], "#123456");
});

test("tile sizes follow the theme and the dock size", () => {
  const b = L.resolveTheme(spec, { theme: "baneyspaces", palette: "nord" }), o = L.resolveTheme(spec, { theme: "omarchy", palette: "nord" });
  assert.ok(L.tileSpecFor(b, "small").icon < L.tileSpecFor(b, "medium").icon);
  assert.ok(L.tileSpecFor(b, "medium").icon < L.tileSpecFor(b, "large").icon);
  assert.strictEqual(L.tileSpecFor(b, "nonsense").icon, L.tileSpecFor(b, "medium").icon);
  assert.ok(L.tileSpecFor(b, "medium").icon > L.tileSpecFor(o, "medium").icon, "the baneyspaces tile is bigger than omarchy's");
  assert.strictEqual(L.tileSpecFor(b, "medium").icon + 16, 64, "a one-icon tile is the theme's space.tile wide");
  assert.strictEqual(L.tileSpecFor(o, "medium").radius, 0);
  assert.strictEqual(L.tileSpecFor(b, "medium").radius, 16);
});

test("pickRect finds the tile under a point, edges half-open", () => {
  const rects = [{ x: 0, y: 0, w: 10, h: 10 }, { x: 10, y: 0, w: 10, h: 10 }];
  assert.strictEqual(L.pickRect(rects, 5, 5), 0);
  assert.strictEqual(L.pickRect(rects, 10, 5), 1);
  assert.strictEqual(L.pickRect(rects, 20, 5), -1);
  assert.strictEqual(L.pickRect(rects, 5, -1), -1);
  assert.strictEqual(L.pickRect([], 0, 0), -1);
});

test("a list stands on its tile and stays on screen", () => {
  const tile = { x: 500, y: 900, w: 80, h: 60 };
  assert.deepStrictEqual(L.listPlacement(tile, { w: 200, h: 100 }, { w: 1920 }, 8), { x: 440, y: 792 });
  assert.strictEqual(L.listPlacement({ x: 0, y: 900, w: 60, h: 60 }, { w: 200, h: 100 }, { w: 1920 }, 8).x, 8);
  assert.strictEqual(L.listPlacement({ x: 1900, y: 900, w: 60, h: 60 }, { w: 200, h: 100 }, { w: 1920 }, 8).x, 1712);
});

test("stepIndex wraps both ways", () => {
  assert.strictEqual(L.stepIndex(2, 3, 1), 0);
  assert.strictEqual(L.stepIndex(0, 3, -1), 2);
  assert.strictEqual(L.stepIndex(0, 0, 1), 0);
});

test("clicking an app again goes to its next window", () => {
  const w = [{ window: "a", focused: false }, { window: "b", focused: true }, { window: "c", focused: false }];
  assert.strictEqual(L.nextWindow(w, null), "c");
  assert.strictEqual(L.nextWindow([{ window: "a" }, { window: "b" }], null), "a");
  assert.strictEqual(L.nextWindow([{ window: "a", focused: true }], null), "a");
  assert.strictEqual(L.nextWindow([], null), null);
});

test("launcher results get section headers and keep their flat index", () => {
  const rows = L.sectionRows([{ section: "Apps", title: "A" }, { section: "Apps", title: "B" }, { section: "Web", title: "C" }]);
  assert.deepStrictEqual(rows.map((r) => r.header || r.title), ["Apps", "A", "B", "Web", "C"]);
  assert.deepStrictEqual(rows.filter((r) => !r.header).map((r) => r.index), [0, 1, 2]);
});

test("Tab cycles the launcher's menus and skips switched-off ones", () => {
  assert.strictEqual(L.nextMode("all", 1, {}), "apps");
  assert.strictEqual(L.nextMode("workspaces", 1, {}), "all");
  assert.strictEqual(L.nextMode("all", -1, {}), "workspaces");
  assert.strictEqual(L.nextMode("apps", 1, { files: false }), "install");
  assert.strictEqual(L.nextMode("apps", 1, { files: false, install: false, remove: false }), "update");
});

test("badges", () => {
  assert.strictEqual(L.badgeGlyph("asking", 0), "?");
  assert.strictEqual(L.badgeGlyph("error", 0), "!");
  assert.strictEqual(L.badgeGlyph("finished", 3), "3");
  assert.strictEqual(L.badgeGlyph("finished", 1), "•");
  assert.strictEqual(L.badgeGlyph("working", 0), "");
  assert.strictEqual(L.moreLabel(3), "+3");
  assert.strictEqual(L.moreLabel(0), "");
  assert.strictEqual(L.rowTitle({ title: "", app: "foot" }), "foot");
});

test("the overview grid is 3 x 3 and arrows stop at the edges", () => {
  const r = L.gridRect(4, 900, 600, 10);
  assert.ok(r.x > 10 && r.y > 10 && r.w > 0 && r.h > 0);
  const last = L.gridRect(8, 900, 600, 10);
  assert.ok(last.x + last.w <= 900 && last.y + last.h <= 600);
  assert.strictEqual(L.gridMove(0, "left"), 0);
  assert.strictEqual(L.gridMove(0, "right"), 1);
  assert.strictEqual(L.gridMove(2, "right"), 2);
  assert.strictEqual(L.gridMove(4, "up"), 1);
  assert.strictEqual(L.gridMove(7, "down"), 7);
});

// ---- themes ----------------------------------------------------------------------------------------------
const hex6 = /^#[0-9a-f]{6}$/;

test("the plugin's role mapping reproduces every bundled palette of spec/palettes.json from Omarchy's colors.toml", () => {
  const root = "/usr/share/omarchy/themes";
  if (!fs.existsSync(root)) return;
  let n = 0;
  for (const name of fs.readdirSync(root)) {
    const f = path.join(root, name, "colors.toml");
    if (!fs.existsSync(f)) continue;
    const p = L.paletteFromColors(L.parseColors(fs.readFileSync(f, "utf8")));
    assert.deepStrictEqual(p, spec.palettes.palettes[name], name);
    n++;
  }
  assert.ok(n >= 20, "found the themes");
});

test("a custom theme without dark/lighter backgrounds still maps (the user's own, like martyr)", () => {
  const p = L.paletteFromColors(L.parseColors('mode = "dark"\naccent = "#d5b66f"\nbackground = "#1e181b"\nforeground = "#fffaff"\nbright_foreground = "#fffaff"\nlight_foreground = "#eee5d5"\ndark_foreground = "#b9aaa6"\nmuted = "#9c8782"\nselection = "#5e4f38"\nred = "#ee8991"\ngreen = "#82c89c"\nyellow = "#dfb866"\nblue = "#8ab4dc"\n'));
  assert.strictEqual(p.surface, "#1e181b");
  assert.strictEqual(p.sunken, "#1e181b");
  assert.strictEqual(p.accent, "#d5b66f");
  assert.strictEqual(p.border, "#9c8782");
  assert.strictEqual(L.paletteFromColors({ background: "#000000" }), null);
});

test("every theme resolves against every palette and the live one, with every token a surface reads", () => {
  const tokyo = L.parseColors('accent = "#7aa2f7"\nbackground = "#1a1b26"\nforeground = "#a9b1d6"\nmuted = "#414868"\nred = "#f7768e"\nyellow = "#e0af68"\ngreen = "#9ece6a"\n');
  for (const theme of Object.keys(spec.themes)) {
    for (const pal of [...Object.keys(spec.palettes.palettes), "auto"]) {
      const r = L.resolveTheme(spec, { theme, palette: pal, auto: tokyo, reduce: false });
      assert.strictEqual(r.theme, theme);
      for (const k of ["bar", "tile", "row", "list"]) assert.strictEqual(r.radius[k], spec.themes[theme].radius[k], `${theme}.radius.${k}`);
      assert.strictEqual(r.border.width, spec.themes[theme].border.width);
      assert.match(r.border.color, hex6);
      assert.match(r.fill.color, hex6);
      assert.strictEqual(r.tints.length, 9);
      r.tints.forEach((t) => assert.match(t, hex6));
      assert.strictEqual(r.indicator, spec.themes[theme].indicator);
      assert.ok(r.font.families.length > 0);
    }
  }
});

test("the three looks: omarchy is blocky and opaque, baneyspaces is rounded and translucent with a white gradient border", () => {
  const pal = "tokyo-night";
  const o = L.resolveTheme(spec, { theme: "omarchy", palette: pal, reduce: false });
  assert.deepStrictEqual([o.radius.bar, o.radius.tile, o.radius.row, o.radius.list], [0, 0, 0, 0]);
  assert.strictEqual(o.border.width, 2);
  assert.strictEqual(o.border.focusedColor, spec.palettes.palettes[pal].accent, "the accent when focused");
  assert.strictEqual(o.fill.solid, true);
  assert.strictEqual(o.fill.color, spec.palettes.palettes[pal].background);
  assert.strictEqual(o.shadow, null);
  assert.strictEqual(o.indicator, "number-block");
  assert.strictEqual(o.scaling, false);
  assert.strictEqual(o.motion.slide, 0, "fades only: scale_from 1.0 means no slide either");
  assert.strictEqual(o.motion.lift, 1);
  const b = L.resolveTheme(spec, { theme: "baneyspaces", palette: pal, reduce: false });
  assert.deepStrictEqual([b.radius.bar, b.radius.tile, b.radius.row, b.radius.list], [24, 16, 7, 14]);
  assert.strictEqual(b.border.color, "#ffffff");
  assert.deepStrictEqual(b.border.gradient, { top: 0.22, bottom: 0.06 });
  assert.strictEqual(b.border.focusedColor, null, "the workspace's own tint, chosen per tile");
  assert.strictEqual(b.fill.solid, false);
  assert.strictEqual(b.fill.opacity, 0.88);
  assert.strictEqual(b.fill.color, spec.palettes.palettes[pal].background, "the fill is the background under opacity 0.88");
  assert.notStrictEqual(b.shadow, null);
  assert.deepStrictEqual([b.motion.dockIn, b.motion.dockOut, b.motion.listIn, b.motion.listOut, b.motion.row, b.motion.listFrom, b.motion.lift, b.motion.slide], [180, 140, 140, 100, 80, 0.96, 1.04, 8]);
  const m = L.resolveTheme(spec, { theme: "minimal", palette: pal, reduce: false });
  assert.strictEqual(m.indicator, "bar");
  assert.strictEqual(m.fill.opacity, 0.96);
});

test("opacity is yours to change only where the theme says adjustable", () => {
  assert.strictEqual(L.resolveTheme(spec, { theme: "baneyspaces", palette: "nord", opacity: 0.5 }).fill.opacity, 0.5);
  assert.strictEqual(L.resolveTheme(spec, { theme: "omarchy", palette: "nord", opacity: 0.5 }).fill.opacity, 1.0);
  assert.strictEqual(L.resolveTheme(spec, { theme: "minimal", palette: "nord", opacity: 0.5 }).fill.opacity, 0.96);
});

test("reduced motion is instant in every theme", () => {
  for (const theme of Object.keys(spec.themes)) {
    const r = L.resolveTheme(spec, { theme, palette: "nord", reduce: true });
    assert.deepStrictEqual(Object.values(r.motion).filter((v) => v !== 1 && v !== 0), [], theme);
  }
});

test("an unknown theme or palette falls back instead of leaving a surface without tokens", () => {
  const r = L.resolveTheme(spec, { theme: "nope", palette: "nope" });
  assert.strictEqual(r.theme, "omarchy");
  assert.strictEqual(r.palette, "tokyo-night");
  assert.strictEqual(L.resolveTheme(spec, { theme: "omarchy", palette: "auto", auto: null }).palette, "tokyo-night");
});

test("light is white and workspace is the tile's own tint", () => {
  const p = spec.palettes.palettes.nord;
  assert.strictEqual(L.roleColor(p, "light", null), "#ffffff");
  assert.strictEqual(L.roleColor(p, "workspace", "#123456"), "#123456");
  assert.strictEqual(L.roleColor(p, "accent", null), p.accent);
});

test("no surface hard-codes a color, a radius or a duration (spec/themes.md: every surface uses the theme)", () => {
  const dir = path.join(__dirname, "../omarchy/plugins/io.github.baney75.baneyspaces");
  const bad = [];
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith(".qml"))) {
    fs.readFileSync(path.join(dir, f), "utf8").split("\n").forEach((line, i) => {
      if (/structural/.test(line)) return;
      if (/"#[0-9a-fA-F]{3,8}"/.test(line)) bad.push(`${f}:${i + 1} color literal: ${line.trim()}`);
      if (/\bradius:\s*[1-9]/.test(line)) bad.push(`${f}:${i + 1} radius literal: ${line.trim()}`);
      if (/\bduration:\s*[1-9]/.test(line)) bad.push(`${f}:${i + 1} duration literal: ${line.trim()}`);
    });
  }
  assert.deepStrictEqual(bad, []);
});

test("animation presets, speed, your own times and reduced motion (spec/config.md)", () => {
  const m = spec.themes.baneyspaces.motion;
  const base = L.motionFor(m, {}, false);
  assert.deepStrictEqual([base.dockIn, base.dockOut, base.listIn, base.listOut, base.row, base.listFrom, base.lift, base.slide], [180, 140, 140, 100, 80, 0.96, 1.04, 8]);
  const om = L.motionFor(m, { preset: "omarchy" }, false);
  assert.deepStrictEqual([om.dockIn, om.dockOut, om.listIn, om.listOut], [410, 149, 400, 150], "Omarchy's own curves in ms");
  assert.strictEqual(om.slide, 0, "popin, not a slide");
  assert.strictEqual(L.motionFor(m, { preset: "snappy" }, false).dockIn, 108);
  assert.strictEqual(L.motionFor(m, { preset: "smooth" }, false).dockIn, 234);
  assert.strictEqual(L.motionFor(m, { speed: 0.5 }, false).dockIn, 90);
  assert.strictEqual(L.motionFor(m, { dock_in_ms: 90, speed: 2 }, false).dockIn, 180, "your time, then the speed");
  assert.strictEqual(L.motionFor(m, { dock_in_ms: -1 }, false).dockIn, 180, "-1 means the preset");
  for (const cfg of [{ preset: "off" }, { speed: 0 }, {}]) {
    const r = L.motionFor(m, cfg, cfg.preset === undefined && cfg.speed === undefined);
    assert.deepStrictEqual([r.dockIn, r.dockOut, r.listIn, r.listOut, r.row, r.slide], [0, 0, 0, 0, 0, 0]);
    assert.deepStrictEqual([r.listFrom, r.lift], [1, 1]);
  }
});

test("a theme override changes tokens for this machine only", () => {
  const r = L.resolveTheme(spec, { theme: "baneyspaces", palette: "nord", override: { radius: { tile: 4 }, fill: { opacity: 0.5 }, font: { family: "monospace" } } });
  assert.strictEqual(r.radius.tile, 4);
  assert.strictEqual(r.radius.bar, 24, "the rest of radius is the theme's");
  assert.strictEqual(r.fill.opacity, 0.5);
  assert.deepStrictEqual(r.font.families, ["JetBrainsMono Nerd Font", "monospace"]);
  assert.strictEqual(spec.themes.baneyspaces.radius.tile, 16, "the spec's own tokens are untouched");
  assert.strictEqual(L.resolveTheme(spec, { theme: "omarchy", palette: "nord", override: { fill: { opacity: 0.5 } } }).fill.opacity, 0.5, "any token can be set, as the spec says");
});

test("every icon the launcher uses for a row that is not an app has a glyph (no missing-image checker)", () => {
  const rs = fs.readFileSync(path.join(__dirname, "../baneyspaces/src/launcher.rs"), "utf8");
  const m = rs.match(/BUILTIN_ICONS: &\[&str\] = &\[([\s\S]*?)\];/);
  assert.ok(m, "BUILTIN_ICONS in launcher.rs");
  const names = [...m[1].matchAll(/"([a-z-]+)"/g)].map((x) => x[1]);
  assert.ok(names.length >= 10);
  for (const n of names) assert.ok(L.glyphFor(n) !== "", `${n} has no glyph`);
  assert.strictEqual(L.glyphFor("firefox"), "", "an app's own icon is not a glyph");
});

test("the pending list is read from config.json, keeping only well-formed entries", () => {
  const id = "a".repeat(64);
  const text = JSON.stringify({ pending: [{ id, path: "hooks.on_switch", value: "echo hi", kind: "hook", written_by_hint: "agent:x" }, { id: "short", path: "x" }, { path: "no id" }, null] });
  assert.deepStrictEqual(L.pendingOf(text).map((p) => p.id), [id]);
  assert.deepStrictEqual(L.pendingOf("not json"), []);
  assert.deepStrictEqual(L.pendingOf("{}"), []);
});

test("nothing but a pointer click approves: no key handler or IPC function in the Settings surface calls approve()", () => {
  const q = fs.readFileSync(path.join(__dirname, "../omarchy/plugins/io.github.baney75.baneyspaces/SettingsPanel.qml"), "utf8");
  const calls = [...q.matchAll(/root\.approve\(/g)].length;
  // called from the click handler and from the gated test handler, nowhere else
  assert.strictEqual(calls, 2, "root.approve( appears in the MouseArea and the gated test handler only");
  assert.ok(/pb\.modelData\.ok\) root\.approve\(pe\.modelData\)/.test(q), "the click handler approves");
  assert.ok(/target: "baneyspaces\.settings\.test"\s*\n\s*enabled: root\.testOps/.test(q), "the handler that approves is gated by BANEYSPACES_TEST_OPS");
  const ipc = q.slice(q.indexOf('target: "baneyspaces.settings"'), q.indexOf('// Test only'));
  assert.ok(!/approve/.test(ipc), "the ordinary Settings IPC handler cannot approve");
  // the approve buttons sit inside a MouseArea; no Keys handler in the file approves
  for (const m of q.matchAll(/Keys\.on\w+Pressed:[^\n]*/g)) assert.ok(!/approve/.test(m[0]), m[0]);
  assert.ok(/Qt\.MouseEventSynthesizedByApplication/.test(q), "a click a program made up is refused");
});
