//! The key map from `spec/keys.json`, and the Hyprland config the Linux platform derives from it.

use serde_json::Value;

pub const KEYS_JSON: &str = include_str!("../../../spec/keys.json");

pub fn keys() -> Value {
    serde_json::from_str(KEYS_JSON).expect("spec/keys.json is valid JSON")
}

/// One binding: the Hyprland key string and the `baneyspaces` arguments it runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bind {
    pub keys: String,
    pub description: String,
    pub args: String,
}

/// The Linux bindings in spec order: switch 1-9, move 1-9, move-and-stay 1-9, overview, agent toggle.
pub fn linux_binds() -> Vec<Bind> {
    let k = keys();
    let l = &k["platforms"]["linux"];
    let mut out = vec![];
    for n in 1..=9u8 {
        // Hyprland keycodes for the digit row: 1 is code 10.
        let code = format!("code:{}", 9 + n);
        out.push(Bind { keys: l["switch"].as_str().unwrap().replace("{key}", &code), description: format!("BaneySpaces: workspace {n}"), args: format!("switch {n}") });
    }
    for n in 1..=9u8 {
        let code = format!("code:{}", 9 + n);
        out.push(Bind { keys: l["move"].as_str().unwrap().replace("{key}", &code), description: format!("BaneySpaces: send window to workspace {n}"), args: format!("move {n}") });
    }
    for n in 1..=9u8 {
        let code = format!("code:{}", 9 + n);
        out.push(Bind { keys: l["move_stay"].as_str().unwrap().replace("{key}", &code), description: format!("BaneySpaces: send window to workspace {n}, stay here"), args: format!("move {n} --stay") });
    }
    out.push(Bind { keys: l["overview"].as_str().unwrap().into(), description: "BaneySpaces: overview".into(), args: "overview".into() });
    out.push(Bind { keys: l["agent_toggle"].as_str().unwrap().into(), description: "BaneySpaces: show or hide the agent workspace".into(), args: "agent-workspace toggle".into() });
    out
}

/// Omarchy's own bindings that BaneySpaces replaces: unbound first, restored on uninstall.
pub fn linux_unbinds() -> Vec<String> {
    let k = keys();
    k["platforms"]["linux"]["replaces"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

/// The part of the include that installs a keys file. All or nothing: the previous keys come out, the new
/// ones go in, and if any one of them cannot be bound (or a mode cannot be defined) everything just bound is
/// taken out again and the default keys are put back, so a bad bind never leaves a session without workspace
/// keys. (A bind Hyprland cannot make answers with a nil handle; `hl.bind` does not raise.)
const LUA_INSTALL: &str = r#"__baneyspaces_keys, __baneyspaces_mode_binds, __baneyspaces_loaded = {}, {}, false

function __baneyspaces_note_failure(msg)
  if __baneyspaces_notified then return end
  __baneyspaces_notified = true
  local ef = io.open(state .. "/keys-error.txt", "w")
  if ef then ef:write(msg, "\n") ef:close() end
  hl.exec_cmd("notify-send -a BaneySpaces 'BaneySpaces: your keys could not be installed' 'The default keys are on. See keys-error.txt in the BaneySpaces state folder.'")
end

function __baneyspaces_install(spec)
  __baneyspaces_notified = false
  -- Leave a mode this config no longer has: its binds are about to be disabled, and Hyprland applies only a
  -- submap's own binds while one is active.
  local names = {}
  for _, m in ipairs(spec.modes or {}) do names[m.name] = true end
  local okc, cur = pcall(hl.get_current_submap)
  if okc and cur and cur ~= "" and cur ~= "reset" and cur ~= "default" and not names[cur] then
    pcall(hl.dispatch, hl.dsp.submap("reset"))
  end
  -- Hyprland 0.56.2 crashes when more than one bind is removed through its handle: global binds come out by
  -- key (hl.unbind) and mode binds are disabled.
  for _, k in ipairs(__baneyspaces_keys) do pcall(hl.unbind, k) end
  for _, b in ipairs(__baneyspaces_mode_binds) do pcall(function() b:set_enabled(false) end) end
  for _, k in ipairs(DEFAULT_KEYS) do pcall(hl.unbind, k) end
  for _, k in ipairs(spec.steal or {}) do pcall(hl.unbind, k) end
  local keys, mode_binds, failed = {}, {}, {}
  local in_mode = false
  local function bind(chord, dsp, desc)
    local ok, b = pcall(hl.bind, chord, dsp, { description = desc })
    if not (ok and b) then
      failed[#failed + 1] = tostring(chord)
    elseif in_mode then
      table.insert(mode_binds, b)
    else
      table.insert(keys, chord)
    end
  end
  for _, e in ipairs(spec.keys or {}) do bind(e[1], e[2], e[3]) end
  for _, m in ipairs(spec.modes or {}) do
    local ok = pcall(hl.define_submap, m.name, "reset", function()
      in_mode = true
      for _, e in ipairs(m.binds) do bind(e[1], e[2], e[3]) end
      if __baneyspaces_recovery then __baneyspaces_recovery(bind) end
    end)
    in_mode = false
    if not ok then failed[#failed + 1] = "mode " .. tostring(m.name) end
  end
  if #failed > 0 then
    -- Take out what was just bound and put the defaults back.
    for _, k in ipairs(keys) do pcall(hl.unbind, k) end
    for _, b in ipairs(mode_binds) do pcall(function() b:set_enabled(false) end) end
    __baneyspaces_keys, __baneyspaces_mode_binds, __baneyspaces_loaded = {}, {}, false
    __baneyspaces_bind_defaults()
    local msg = "keys not installed: " .. #failed .. " bind(s) failed (" .. table.concat(failed, ", ") .. "); the default keys are on"
    __baneyspaces_note_failure(msg)
    error(msg, 0)
  end
  __baneyspaces_keys, __baneyspaces_mode_binds, __baneyspaces_loaded = keys, mode_binds, true
end
"#;

/// The text of `platforms/linux/omarchy/baneyspaces.lua`. A test keeps the committed file equal to this.
pub fn render_hypr_lua(binary: &str) -> String {
    let mut s = String::new();
    s.push_str("-- BaneySpaces key bindings for Omarchy/Hyprland. Generated by `baneyspaces keys --hypr-lua`\n");
    s.push_str("-- from spec/keys.json; do not edit by hand. Loaded by hyprland.lua after Omarchy's defaults.\n\n");
    s.push_str("-- Omarchy's own bindings for these keys, replaced below (install.sh backs up what it changes).\n");
    for u in linux_unbinds() {
        s.push_str(&format!("hl.unbind(\"{u}\")\n"));
    }
    s.push_str("\n-- Workspace animations off: a BaneySpaces switch is instant.\n");
    s.push_str("hl.animation({ leaf = \"workspaces\", enabled = false })\n");
    s.push_str("hl.animation({ leaf = \"specialWorkspace\", enabled = false })\n\n");
    s.push_str("-- Apps may ask for focus; only you take it. The daemon guards the agent workspace as well.\n");
    s.push_str("hl.config({ misc = { focus_on_activate = false } })\n\n");
    s.push_str("-- The recovery chord: hold Super+Shift+Escape for two seconds to put the default keys and theme back.\n");
    s.push_str("-- Bound here, always, and again inside every mode. Config can neither bind nor remove it (spec/config.md).\n");
    s.push_str("-- A hold is continuous: every 100 ms all three keys must still be down, any release cancels it, and a newer\n");
    s.push_str("-- press makes an older one void. (hl.is_key_down takes keysym names; an unknown name answers nil.)\n");
    s.push_str("__baneyspaces_hold_gen = 0\n");
    s.push_str("local function key_down(left, right) return hl.is_key_down(left) or (right ~= nil and hl.is_key_down(right)) end\n");
    s.push_str("local function chord_held()\n  return key_down(\"Super_L\", \"Super_R\") and key_down(\"Shift_L\", \"Shift_R\") and key_down(\"Escape\")\nend\n");
    s.push_str("function __baneyspaces_recovery_fire()\n");
    s.push_str("  pcall(hl.dispatch, hl.dsp.submap(\"reset\"))\n");
    s.push_str(&format!("  hl.exec_cmd(\"{binary} config reset keys --notify\")\n  hl.exec_cmd(\"{binary} config reset theme --notify\")\nend\n"));
    s.push_str(&format!("function __baneyspaces_recovery_press()\n  __baneyspaces_hold_gen = __baneyspaces_hold_gen + 1\n  local gen, waited = __baneyspaces_hold_gen, 0\n  local function tick()\n    if gen ~= __baneyspaces_hold_gen or not chord_held() then return end\n    waited = waited + 100\n    if waited >= {} then\n      __baneyspaces_recovery_fire()\n    else\n      hl.timer(tick, {{ timeout = 100, type = \"oneshot\" }})\n    end\n  end\n  hl.timer(tick, {{ timeout = 100, type = \"oneshot\" }})\nend\n", crate::chord::recovery_hold_ms()));
    s.push_str("function __baneyspaces_recovery(bindfn)\n");
    s.push_str("  bindfn(\"SUPER + SHIFT + Escape\", function() __baneyspaces_recovery_press() end, \"BaneySpaces: recovery (hold 2 s)\")\nend\n");
    s.push_str("__baneyspaces_recovery(function(keys, dsp, desc) hl.bind(keys, dsp, { description = desc }) end)\n\n");
    s.push_str("local state = (os.getenv(\"XDG_STATE_HOME\") or ((os.getenv(\"HOME\") or \"\") .. \"/.local/state\")) .. \"/baneyspaces\"\n\n");
    s.push_str("-- The default keys: they keep every workspace key working until the daemon has written yours, with no\n");
    s.push_str("-- daemon, and whenever your keys cannot all be installed.\n");
    s.push_str("function __baneyspaces_bind_defaults()\n");
    for b in linux_binds() {
        s.push_str(&format!("  pcall(hl.unbind, \"{}\")\n", b.keys));
    }
    for b in linux_binds() {
        s.push_str(&format!("  hl.bind(\"{}\", hl.dsp.exec_cmd(\"{} {}\"), {{ description = \"{}\" }})\n", b.keys, binary, b.args, b.description));
    }
    s.push_str("end\n\n");
    s.push_str("local DEFAULT_KEYS = {");
    for b in linux_binds() {
        s.push_str(&format!(" \"{}\",", b.keys));
    }
    s.push_str(" }\n\n");
    s.push_str(LUA_INSTALL);
    s.push_str("\n-- Your keys: the daemon writes them from config.toml (baneyspaces config set keys.bindings...) as a table handed\n");
    s.push_str("-- to __baneyspaces_install. A file that fails to run, or whose keys cannot all be bound, leaves the defaults on\n");
    s.push_str("-- and says why in keys-error.txt next to it.\n");
    s.push_str("local generated = state .. \"/hyprland-keys.lua\"\n");
    s.push_str("local gf = io.open(generated, \"r\")\n");
    s.push_str("if gf then\n  gf:close()\n  __baneyspaces_notified = false\n  local ok, err = pcall(dofile, generated)\n  if not ok then\n    __baneyspaces_note_failure(tostring(err))\n    __baneyspaces_loaded = false\n  end\nend\n");
    s.push_str("if not __baneyspaces_loaded then\n  __baneyspaces_bind_defaults()\nend\n");
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_has_twenty_nine_binds_and_unique_keys() {
        let b = linux_binds();
        assert_eq!(b.len(), 29);
        let mut keys: Vec<_> = b.iter().map(|b| b.keys.clone()).collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), 29);
        assert!(b.iter().any(|b| b.keys == "SUPER + code:12" && b.args == "switch 3"));
        assert!(b.iter().any(|b| b.keys == "SUPER + SHIFT + code:18" && b.args == "move 9"));
    }

    #[test]
    fn every_bound_key_is_unbound_first_when_omarchy_owns_it() {
        let un = linux_unbinds();
        for b in linux_binds() {
            if b.args == "overview" || b.args.starts_with("switch") || b.args.starts_with("move") {
                assert!(un.contains(&b.keys), "{} is not in `replaces`", b.keys);
            }
        }
    }

    #[test]
    fn the_committed_include_is_what_the_spec_generates() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../platforms/linux/omarchy/baneyspaces.lua");
        if std::env::var("UPDATE_SPEC").is_ok() {
            std::fs::write(path, render_hypr_lua("baneyspaces")).unwrap();
        }
        let committed = std::fs::read_to_string(path).expect("platforms/linux/omarchy/baneyspaces.lua");
        assert_eq!(committed, render_hypr_lua("baneyspaces"), "regenerate with: UPDATE_SPEC=1 cargo test -p baneyspaces-core");
    }

    #[test]
    fn every_platform_has_the_same_actions() {
        let k = keys();
        let actions: Vec<_> = k["actions"].as_object().unwrap().keys().cloned().collect();
        for p in ["macos", "linux", "windows"] {
            for a in &actions {
                assert!(!k["platforms"][p][a].is_null(), "{p} lacks {a}");
            }
        }
    }
}
