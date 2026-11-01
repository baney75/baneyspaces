// Driver-level latency of ChatGPT's computer-use primitives (@oai/sky window API), called directly.
// Usage (from bench/harness.py, with the node that ships in ChatGPT.app):
//   node chatgpt_micro.mjs <reps> <textEditApp> <calculatorApp>
// Prints one JSON object {snapshot:[ms..], click:[..], type:[..], "read-back":[..], errors:[..]}.
// Same four rows as the CLI tools: read-back is a fresh get_app_state with the typed value found in it.
// Timed in-process around each call (the CLI tools are timed per spawned process minus a no-op spawn).
// Only ever run when TextEdit and Calculator were not running before the bench opened them, because
// Sky addresses an app by name, not by window. Unverified until the first run on an idle Mac: if the
// Sky service refuses a headless caller it prints {"unavailable": "<reason>"} and the harness records n/a.
const SKY = "/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/dist/project/cua/sky_js/src/index.js";
const [reps = "20", textApp = "TextEdit", calcApp = "Calculator"] = process.argv.slice(2);
const out = { snapshot: [], click: [], type: [], "read-back": [], errors: [] };
const time = async (bucket, fn) => {
  const t0 = performance.now();
  try { const r = await fn(); out[bucket].push(performance.now() - t0); return r; }
  catch (e) { out.errors.push(`${bucket}: ${String(e.message || e).slice(0, 160)}`); return null; }
};
const indexOf = (text, pattern) => {
  const line = text.split("\n").find((l) => pattern.test(l));
  const m = line && line.match(/^\s*(\d+)\b/);
  return m ? Number(m[1]) : null;
};
try {
  const { sky } = await import(SKY);
  for (let i = 0; i < Number(reps); i++) {
    const state = await time("snapshot", () => sky.get_app_state({ app: textApp, disableDiff: true }));
    const idx = state && indexOf(state.text, /text (entry )?(area|field|view)/i);
    if (idx == null) { out.errors.push("no text element index in the state text"); continue; }
    const value = `bench ${i}`;
    await time("type", () => sky.set_value({ app: textApp, element_index: idx, value }));
    const back = await time("read-back", () => sky.get_app_state({ app: textApp, disableDiff: true }));
    if (!back || !back.text.includes(value)) out.errors.push("read-back did not show the typed value");
  }
  for (let i = 0; i < Number(reps); i++) {
    const state = await sky.get_app_state({ app: calcApp, disableDiff: true });
    const idx = indexOf(state.text, /\b(all )?clear\b/i);
    if (idx == null) { out.errors.push("no clear button in the Calculator state text"); break; }
    await time("click", () => sky.click({ app: calcApp, element_index: idx }));
  }
} catch (e) {
  console.log(JSON.stringify({ unavailable: String(e.message || e).slice(0, 300) }));
  process.exit(0);
}
console.log(JSON.stringify(out));
