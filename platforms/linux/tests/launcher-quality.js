// Fuzzy-match quality: Omarchy's own app search (shell/services/AppSearch.js, the one behind Super+Alt+Space) against
// the BaneySpaces launcher, on the same installed apps and the same queries.
//   node launcher-quality.js <ours.json>      ours.json: { "<query>": ["<desktop id>", ...ranked] }
//   node launcher-quality.js --queries        prints the queries, one per line
// Each query names the apps a person typing it means. precision@1: the first result is one of them; @3: one is in the
// top three; MRR: 1 / the rank of the first of them. Prints JSON; exit 1 if BaneySpaces is behind on any of the three.
const fs = require("node:fs");
const path = require("node:path");
const omarchy = process.env.OMARCHY_PATH || "/usr/share/omarchy";
const App = require(path.join(omarchy, "shell/services/AppSearch.js"));

const QUERIES = {
  "chrom": ["chromium"], "chromium": ["chromium"], "browser": ["chromium"], "web": ["chromium"],
  "writer": ["libreoffice-writer"], "word": ["libreoffice-writer"], "word proc": ["libreoffice-writer"], "lw": ["libreoffice-writer"],
  "calc": ["libreoffice-calc"], "spreadsheet": ["libreoffice-calc"], "presentation": ["libreoffice-impress"], "impress": ["libreoffice-impress"],
  "draw": ["libreoffice-draw"], "math": ["libreoffice-math"], "base": ["libreoffice-base"],
  "obs": ["com.obsproject.Studio"], "studio": ["com.obsproject.Studio"], "blend": ["blender"], "blender": ["blender"],
  "foot": ["foot"], "term": ["foot"], "terminal": ["foot"], "nvim": ["nvim"], "neovim": ["nvim"], "btop": ["btop"],
  "mpv": ["mpv"], "video": ["mpv"], "player": ["mpv"], "imv": ["imv"], "image": ["imv"], "obsid": ["obsidian"], "obsidian": ["obsidian"],
  "xourn": ["com.github.xournalpp.xournalpp"], "pinta": ["com.github.PintaProject.Pinta"], "moon": ["com.moonlight_stream.Moonlight"],
  "localsend": ["localsend"], "send": ["localsend"], "disk image": ["gnome-disk-image-writer", "gnome-disk-image-mounter"],
};

function desktopEntries() {
  const dir = "/usr/share/applications";
  const hides = new Set(fs.existsSync(path.join(omarchy, "default/omarchy/launcher.hides")) ? fs.readFileSync(path.join(omarchy, "default/omarchy/launcher.hides"), "utf8").split("\n").map((s) => s.trim()).filter(Boolean) : []);
  const out = [];
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith(".desktop"))) {
    const id = f.replace(/\.desktop$/, "");
    const kv = {}; let inEntry = false;
    for (const line of fs.readFileSync(path.join(dir, f), "utf8").split("\n")) {
      if (line.startsWith("[")) { inEntry = line.trim() === "[Desktop Entry]"; continue; }
      const m = inEntry && line.match(/^([A-Za-z-]+)=(.*)$/);
      if (m && !(m[1] in kv)) kv[m[1]] = m[2];
    }
    if (!kv.Name || !kv.Exec || kv.NoDisplay === "true" || kv.Hidden === "true" || hides.has(id)) continue;
    out.push({ id, name: kv.Name, genericName: kv.GenericName || "", comment: kv.Comment || "", keywords: (kv.Keywords || "").split(";").filter(Boolean), noDisplay: false });
  }
  return out;
}

function score(rank, want) {
  const i = rank.findIndex((id) => want.includes(id));
  return { p1: i === 0 ? 1 : 0, p3: i >= 0 && i < 3 ? 1 : 0, mrr: i >= 0 ? 1 / (i + 1) : 0 };
}

if (process.argv[2] === "--queries") { console.log(Object.keys(QUERIES).join("\n")); process.exit(0); }
const entries = desktopEntries();
const ours = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const tot = { omarchy: { p1: 0, p3: 0, mrr: 0 }, baneyspaces: { p1: 0, p3: 0, mrr: 0 } };
const rows = [];
for (const [q, want] of Object.entries(QUERIES)) {
  if (!want.some((w) => entries.some((e) => e.id === w))) continue;     // an app that is not installed here
  const theirs = App.sortedEntries(entries, q).map((r) => r.entry.id);
  const a = score(theirs, want), b = score(ours[q] || [], want);
  for (const k of ["p1", "p3", "mrr"]) { tot.omarchy[k] += a[k]; tot.baneyspaces[k] += b[k]; }
  rows.push({ q, want: want[0], omarchy: theirs[0] || null, baneyspaces: (ours[q] || [])[0] || null, o: a.p1, b: b.p1 });
}
const n = rows.length;
const summary = (t) => ({ p1: +(t.p1 / n).toFixed(3), p3: +(t.p3 / n).toFixed(3), mrr: +(t.mrr / n).toFixed(3) });
const res = { queries: n, omarchy: summary(tot.omarchy), baneyspaces: summary(tot.baneyspaces), misses: rows.filter((r) => !r.b || !r.o).filter((r) => r.o !== r.b).map((r) => ({ q: r.q, want: r.want, omarchy: r.omarchy, baneyspaces: r.baneyspaces })) };
console.log(JSON.stringify(res));
process.exit(res.baneyspaces.p1 >= res.omarchy.p1 && res.baneyspaces.p3 >= res.omarchy.p3 && res.baneyspaces.mrr >= res.omarchy.mrr ? 0 : 1);
