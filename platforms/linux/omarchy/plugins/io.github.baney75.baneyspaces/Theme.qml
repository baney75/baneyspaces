import QtQuick
import Quickshell
import Quickshell.Io
import "Logic.js" as Logic

// The theme and palette every surface draws from (spec/themes.md): shape, type and motion from themes.json,
// color from a palette. `auto` is the live Omarchy theme (colors.toml, read again every 2 s so a theme switch
// shows without a restart). Nothing else in the plugin names a color, radius or duration.
Item {
  id: root
  visible: false

  property var appearance: ({})       // config: { theme, palette, override }
  property var motionCfg: ({})        // config: { preset, speed, dock_in_ms ... }
  property bool reduce: false
  property string themeDir: (Quickshell.env("BANEYSPACES_THEME_DIR") || "") !== ""
    ? Quickshell.env("BANEYSPACES_THEME_DIR")
    : (Quickshell.env("HOME") + "/.local/state/omarchy/current/theme")
  property var c: ({})

  function localPath(name) { return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, "")) }
  FileView { id: themesFile; path: root.localPath("themes.json"); blockLoading: true }
  FileView { id: palettesFile; path: root.localPath("palettes.json"); blockLoading: true }
  readonly property var spec: {
    var t = JSON.parse(themesFile.text())
    return { themes: t.themes, fonts: t.fonts, palettes: JSON.parse(palettesFile.text()) }
  }

  // Everything resolved: tok.radius.bar|tile|row|list, tok.border, tok.fill, tok.shadow, tok.font, tok.space,
  // tok.indicator, tok.motion, tok.roles (palette), tok.tints (the nine workspace colors).
  readonly property var tok: Logic.resolveTheme(spec, {
    theme: appearance.theme, palette: appearance.palette, auto: c, override: appearance.override, motion: motionCfg, reduce: reduce })
  readonly property var roles: tok.roles
  readonly property var palette: tok.tints
  readonly property var motion: tok.motion

  // Roles under the names the surfaces use.
  readonly property string bg: roles.background
  readonly property string fg: roles.foreground
  readonly property string text: roles.strong
  readonly property string dim: roles.muted
  readonly property string accent: roles.accent
  readonly property string urgent: roles.urgent
  readonly property string warn: roles.working
  readonly property string good: roles.done
  readonly property string orange: Logic.mix(roles.working, roles.urgent, 0.5)
  // Quiet fills for tiles and rows: solid themes use the palette's own surfaces, translucent ones a veil of the foreground.
  readonly property string raised: tok.fill.solid ? roles.surface : Logic.alpha(roles.strong, 0.07)
  readonly property string raisedHot: tok.fill.solid ? roles.selection : Logic.alpha(roles.strong, 0.15)
  readonly property string panel: Logic.alpha(tok.fill.color, tok.fill.opacity)
  readonly property string shade: Logic.alpha(roles.sunken, tok.fill.solid ? 1 : 0.6)
  readonly property int shadowPad: tok.shadow ? tok.shadow.radius + tok.shadow.y : 0

  // The first family of the theme's list that is installed (the last is a generic one).
  readonly property string fontFamily: {
    var have = Qt.fontFamilies(), fams = tok.font.families
    for (var i = 0; i < fams.length; i++) if (have.indexOf(fams[i]) >= 0) return fams[i]
    return fams[fams.length - 1]
  }
  // The font that has the glyphs of the rows that are not an app (Nerd Font), else the theme's own.
  readonly property string glyphFont: {
    var have = Qt.fontFamilies(), want = ["JetBrainsMono Nerd Font", "JetBrainsMono NF", "Symbols Nerd Font", "Symbols Nerd Font Mono"]
    for (var i = 0; i < want.length; i++) if (have.indexOf(want[i]) >= 0) return want[i]
    return fontFamily
  }
  // How a chosen row and the filter chips look (what makes the three themes read differently, beyond their borders):
  // omarchy: the row takes the selection fill and its label the accent; the chips are plain text with the active one underlined.
  // baneyspaces: a tinted rounded row with an accent border; pill chips. minimal: a thin accent bar on the row; no chips row.
  readonly property string selectStyle: tok.theme === "omarchy" ? "text" : (tok.theme === "minimal" ? "line" : "pill")
  readonly property string chipStyle: tok.theme === "omarchy" ? "text" : (tok.theme === "minimal" ? "none" : "pill")
  readonly property int fontSize: tok.font.size
  // Sizes in the design are for a 12 pt base; the theme's `font.size` scales them all (spec/themes.md).
  function fs(px) { return Math.max(8, Math.round(px * tok.font.size / 12)) }
  readonly property int fontWeight: tok.font.weight === "medium" ? Font.Medium : Font.Normal

  function reload() { colors.reload() }
  FileView {
    id: colors
    path: root.themeDir + "/colors.toml"
    onLoaded: {
      var parsed = Logic.parseColors(colors.text())
      if (JSON.stringify(parsed) !== JSON.stringify(root.c)) root.c = parsed
    }
  }
  Timer { interval: 2000; repeat: true; running: true; onTriggered: colors.reload() }
}
