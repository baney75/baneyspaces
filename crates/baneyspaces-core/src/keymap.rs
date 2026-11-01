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

/// The Linux bindings in spec order: switch 1-9, move 1-9, move-and-stay 1-9, overview, switcher (forward, back), launcher, agent toggle.
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
    // Super+Tab was Omarchy's "next workspace". It is that still: it opens the overview on the next one, Tab steps,
    // and letting go of Super goes. Shift steps back (it was "previous workspace").
    out.push(Bind { keys: l["overview"].as_str().unwrap().into(), description: "BaneySpaces: overview (next workspace)".into(), args: "overview next".into() });
    out.push(Bind { keys: format!("{} + SHIFT + TAB", l["overview"].as_str().unwrap().split(" + ").next().unwrap()), description: "BaneySpaces: overview (previous workspace)".into(), args: "overview prev".into() });
    out.push(Bind { keys: l["switcher"].as_str().unwrap().into(), description: "BaneySpaces: switch windows across workspaces".into(), args: "switcher next".into() });
    out.push(Bind { keys: format!("{} + SHIFT + {}", l["switcher"].as_str().unwrap().split(" + ").next().unwrap(), l["switcher"].as_str().unwrap().split(" + ").last().unwrap()), description: "BaneySpaces: switch windows backwards".into(), args: "switcher prev".into() });
    out.push(Bind { keys: l["launcher"].as_str().unwrap().into(), description: "BaneySpaces: launcher".into(), args: "launcher toggle".into() });
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

/// Super+N runs in the compositor when Hyprland's own focus is exactly what BaneySpaces would do (the workspace is not yet
/// made, or is on the display you are on, or is showing on another display, and the agent workspace is not up): no process
/// to start, as fast as Omarchy's own bind. Anything else asks the daemon. The daemon hears of the change like any other.
pub const SWITCH_HELPER: &str = r#"
-- Super+N: do Hyprland's own focus when that is exactly what BaneySpaces would do (no process to start); else ask the daemon.
function baneyspaces_switch(n)
  local fast = false
  if not hl.get_active_special_workspace() then
    local here = hl.get_active_monitor()
    local target = nil
    for _, w in ipairs(hl.get_workspaces()) do
      if w.id == n then target = w end
    end
    if target == nil then
      fast = true
    elseif target.monitor ~= nil and here ~= nil and target.monitor.name == here.name then
      fast = true
    else
      for _, m in ipairs(hl.get_monitors()) do
        if m.active_workspace ~= nil and m.active_workspace.id == n then fast = true end
      end
    end
  end
  if fast then
    hl.dispatch(hl.dsp.focus({ workspace = tostring(n) }))
  else
    hl.dispatch(hl.dsp.exec_raw("baneyspaces switch " .. tostring(n)))
  end
end

"#;

/// Alt+Tab and Super+Tab are held keys. The overlay they open cannot be trusted to see the key come up (a quick tap is over
/// before any surface could take the keyboard), so the compositor remembers the press and acts on the release: a tap goes
/// straight to the window or workspace with no overlay at all, a hold shows the overlay and the release commits it.
pub const HOLD_HELPER: &str = r#"
baneyspaces_held = { alt = false, super = false }
function baneyspaces_press(kind, action)
  baneyspaces_held[kind] = true
  hl.dispatch(hl.dsp.exec_raw("baneyspaces " .. action))
end
function baneyspaces_release(kind, action)
  if baneyspaces_held[kind] then
    baneyspaces_held[kind] = false
    hl.dispatch(hl.dsp.exec_raw("baneyspaces " .. action))
  end
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
    s.push_str("\n-- The shell plugin animates its own panels; the compositor must not add a second animation. Panels with a translucent fill (the baneyspaces theme) are blurred behind.\n");
    s.push_str("hl.layer_rule({ match = { namespace = \"^baneyspaces-.*\" }, no_anim = true, animation = \"none\", blur = true, ignore_alpha = 0.2 })\n");
    s.push_str("\n-- A workspace switch is instant, as in Omarchy's own looknfeel (its `workspaces` animation is off). The daemon keeps the\n");
    s.push_str("-- `workspaces` leaf off unless `animation.workspace.style` in config.toml asks for fade or slide; it touches no other\n");
    s.push_str("-- animation of Omarchy's.\n\n");
    s.push_str("-- Apps may ask for focus; only you take it. The daemon guards the agent workspace as well.\n");
    s.push_str("hl.config({ misc = { focus_on_activate = false } })\n\n");
    s.push_str(SWITCH_HELPER);
    s.push_str(HOLD_HELPER);
    for b in linux_binds() {
        if let Some(n) = b.args.strip_prefix("switch ") {
            s.push_str(&format!("hl.bind(\"{}\", function() baneyspaces_switch({n}) end, {{ description = \"{}\" }})\n", b.keys, b.description));
        } else if b.args.starts_with("switcher ") || b.args.starts_with("overview ") {
            // Held keys: the compositor remembers that the modifier is down and acts on its release.
            let kind = if b.args.starts_with("switcher ") { "alt" } else { "super" };
            s.push_str(&format!("hl.bind(\"{}\", function() baneyspaces_press(\"{kind}\", \"{}\") end, {{ description = \"{}\" }})\n", b.keys, b.args, b.description));
        } else {
            s.push_str(&format!("hl.bind(\"{}\", hl.dsp.exec_raw(\"{} {}\"), {{ description = \"{}\" }})\n", b.keys, binary, b.args, b.description));
        }
    }
    // The releases. Which spelling Hyprland matches (the modifier alone, or the modifier together with itself) is not
    // guaranteed across versions, so both are bound; the first one that runs consumes the "held" mark.
    for (kind, names, mod_name, action) in [("alt", ["Alt_L", "Alt_R"], "ALT", "switcher commit"), ("super", ["Super_L", "Super_R"], "SUPER", "overview go")] {
        for name in names {
            for keys in [name.to_string(), format!("{mod_name} + {name}")] {
                s.push_str(&format!("hl.bind(\"{keys}\", function() baneyspaces_release(\"{kind}\", \"{action}\") end, {{ release = true, description = \"BaneySpaces: {mod_name} let go ({action})\" }})\n"));
            }
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_has_thirty_three_binds_and_unique_keys() {
        let b = linux_binds();
        assert_eq!(b.len(), 33);
        let mut keys: Vec<_> = b.iter().map(|b| b.keys.clone()).collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), 33);
        assert!(b.iter().any(|b| b.keys == "SUPER + code:12" && b.args == "switch 3"));
        assert!(b.iter().any(|b| b.keys == "SUPER + SHIFT + code:18" && b.args == "move 9"));
    }

    #[test]
    fn every_bound_key_is_unbound_first_when_omarchy_owns_it() {
        let un = linux_unbinds();
        for b in linux_binds() {
            if b.args.starts_with("overview") || b.args == "launcher toggle" || b.args.starts_with("switch") || b.args.starts_with("move") {
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
