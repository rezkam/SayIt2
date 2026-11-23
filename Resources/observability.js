// Observability tab: golden signals per provider, takeaways, latency, traffic, errors,
// saturation, accuracy and input signals, a trace explorer, a Prometheus-style metrics explorer, and SQL,
// all read from the local telemetry database through the dashboard's read-only ./query endpoint.
// Uses helpers from dashboard.html (esc, fmtDuration) at call time.

const OBS_PROVIDERS = {
  chatgpt: { name: "ChatGPT", color: "#ffde00" },
  deepgram: { name: "Deepgram", color: "#38bdf8" },
  elevenlabs: { name: "ElevenLabs", color: "#f472b6" },
};
const OBS_MIN_N = 5;   // fewer samples than this per provider are shown but never ranked
const obs = {
  page: "overview", range: 7, providers: new Set(Object.keys(OBS_PROVIDERS)),
  sessions: [], streams: [], stamp: null, specs: {}, charts: [],
  dim: "provider", meta: {}, matrix: { col: "noise", signal: "churn" },
  latencyStage: "release", latencyPct: 0.5, trace: null, traceSpan: null,
  traceFilter: { outcome: "all", text: "", minSeconds: 0 },
  metric: { name: null, agg: "p95", by: "gen_ai.provider.name", rows: [], names: [] },
};

// --- Data access ---
async function obsQuery(sql, params = []) {
  const res = await fetch("./query", {
    method: "POST", cache: "no-store", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sql, params }),
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  const out = await res.json();
  if (out.error) throw new Error(out.error);
  return out;
}
const obsRows = out => out.rows.map(r => Object.fromEntries(out.columns.map((c, i) => [c, r[i]])));
const SQL_SESSIONS = "SELECT * FROM sessions WHERE start_ns >= ?1 * 1e9 ORDER BY start_ns DESC";
const SQL_STREAMS = "SELECT * FROM streams WHERE start_ns >= ?1 * 1e9 ORDER BY start_ns";

/// Reloads only when the database changed or the range moved. Returns whether data changed.
async function obsLoad(force) {
  const head = obsRows(await obsQuery("SELECT count(*) AS n, max(end_ns) AS last FROM spans"))[0] || {};
  const key = head.n + ":" + head.last + ":" + obs.range;
  if (!force && key === obs.stamp) return false;
  const from = Date.now() / 1000 - obs.range * 86400;
  const [s, st] = await Promise.all([obsQuery(SQL_SESSIONS, [from]), obsQuery(SQL_STREAMS, [from])]);
  obs.sessions = obsRows(s).map(r => ({ ...r, t: r.start_ns / 1e9, attempts: Number(r.attempts) || 1 }));
  obs.streams = obsRows(st).map(r => ({ ...r, t: r.start_ns / 1e9 }));
  obs.stamp = key;
  return true;
}

// --- Helpers ---
const opName = p => obs.meta[p]?.name || OBS_PROVIDERS[p]?.name || p || "unknown";
const opColor = p => obs.meta[p]?.color || OBS_PROVIDERS[p]?.color || "#8a8a8a";
const opDot = p => '<span class="dot" style="background:' + opColor(p) + '"></span>';
const opLabel = p => opDot(p) + esc(opName(p));
const obsSel = () => obs.sessions.filter(s => obs.providers.has(s.provider));
const obsSelStreams = () => obs.streams.filter(s => obs.providers.has(s.provider));
function quantile(values, p) {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b), i = (s.length - 1) * p, lo = Math.floor(i), hi = Math.ceil(i);
  return s[lo] + (s[hi] - s[lo]) * (i - lo);
}
const nums = (list, col) => list.map(s => s[col]).filter(v => v != null && Number.isFinite(Number(v))).map(Number);
const sum = values => values.reduce((a, b) => a + b, 0);
const completed = list => list.filter(s => s.outcome === "completed");
const decided = list => list.filter(s => s.outcome !== "cancelled");
const share = (list, pred) => list.length ? { value: list.filter(pred).length / list.length, n: list.length } : { value: null, n: 0 };
const fmtS = v => v == null || !Number.isFinite(v) ? "-" : v < 1 ? Math.round(v * 1000) + " ms" : v < 10 ? v.toFixed(2) + " s" : v < 120 ? v.toFixed(1) + " s" : (v / 60).toFixed(1) + " min";
const fmtPct = v => v == null ? "-" : (v === 0 || v >= 0.1 ? Math.round(v * 100) : (v * 100).toFixed(1)) + "%";
const fmtInt = v => v == null ? "-" : Math.round(v).toLocaleString();
const fmtDb = v => v == null ? "-" : Number(v).toFixed(1) + " dBFS";
const fmtWhen = t => new Date(t * 1000).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" });
const latency = col => list => { const v = nums(completed(list), col); return { value: quantile(v, 0.5), p95: quantile(v, 0.95), n: v.length }; };

// Every comparable signal, grouped by golden signal. `better` marks signals where a provider can win.
const SIGNALS = [
  { key: "release", group: "latency", label: "Release to text", hint: "Key released to the provider's final text: what you wait for", better: "low", fmt: fmtS, calc: latency("release_s"), win: "is fastest from release to final text" },
  { key: "finish", group: "latency", label: "Finalization", hint: "Last audio sent to the final text", better: "low", fmt: fmtS, calc: latency("finish_s"), win: "finalizes fastest" },
  { key: "first", group: "latency", label: "First words", hint: "First audio sent to the first live words (includes when you start speaking)", better: "low", fmt: fmtS, calc: latency("first_text_s"), win: "shows the first words soonest" },
  { key: "connect", group: "latency", label: "Connect", hint: "Connection request to WebSocket handshake done", better: "low", fmt: fmtS, calc: latency("connect_s"), win: "connects fastest" },
  { key: "typing", group: "latency", label: "Typing", hint: "Final text typed into the field, sessions without a focus wait", fmt: fmtS, calc: latency("typing_s") },
  { key: "tail", group: "latency", label: "Release to text p95", hint: "Slowest 5% of dictations", better: "low", fmt: fmtS, calc: l => { const v = nums(completed(l), "release_s"); return { value: quantile(v, 0.95), n: v.length }; }, win: "has the steadiest tail latency" },
  { key: "dictations", group: "traffic", label: "Dictations", fmt: fmtInt, calc: l => ({ value: l.length, n: l.length }) },
  { key: "audio", group: "traffic", label: "Audio", fmt: v => v == null ? "-" : fmtDuration(v), calc: l => ({ value: sum(nums(l, "audio_s")), n: l.length }) },
  { key: "connections", group: "traffic", label: "Connections", fmt: fmtInt, calc: (l, st) => ({ value: st.length, n: st.length }) },
  { key: "words", group: "traffic", label: "Words", fmt: fmtInt, calc: l => ({ value: sum(nums(l, "words")), n: l.length }) },
  { key: "success", group: "errors", label: "Success rate", hint: "Completed out of completed plus failed (cancels excluded)", better: "high", fmt: fmtPct, calc: l => share(decided(l), s => s.outcome === "completed"), win: "is the most reliable" },
  { key: "clean", group: "errors", label: "Clean first try", hint: "Completed without a reconnect", better: "high", fmt: fmtPct, calc: l => share(decided(l), s => s.outcome === "completed" && s.attempts <= 1), win: "completes most often on the first connection" },
  { key: "connErrors", group: "errors", label: "Connection errors", hint: "Connections that ended with an error, including retried ones", better: "low", fmt: fmtPct, calc: (l, st) => share(st, s => !!s.error_type), win: "has the fewest connection errors" },
  { key: "empty", group: "errors", label: "Empty results", hint: "More than 1 s of audio but no text", better: "low", fmt: fmtPct, calc: l => share(decided(l).filter(s => s.audio_s > 1), s => !Number(s.characters)), win: "returns the fewest empty results" },
  { key: "errorLatency", group: "errors", label: "Time to fail (p50)", hint: "How long failed dictations ran before ending", fmt: fmtS, calc: l => { const v = nums(l.filter(s => s.outcome === "failed"), "duration_s"); return { value: quantile(v, 0.5), n: v.length }; } },
  { key: "backlog", group: "saturation", label: "Send backlog p95", hint: "Most audio waiting to go out during a dictation", better: "low", fmt: fmtS, calc: l => { const v = nums(l, "backlog_max_s"); return { value: quantile(v, 0.95), n: v.length }; }, win: "keeps the smallest send backlog" },
  { key: "reconnects", group: "saturation", label: "Reconnects per 100", better: "low", fmt: v => v == null ? "-" : v.toFixed(1), calc: l => { const d = decided(l); return { value: d.length ? 100 * sum(d.map(s => Math.max(0, s.attempts - 1))) / d.length : null, n: d.length }; }, win: "needs the fewest reconnects" },
  { key: "replay", group: "saturation", label: "Largest replay", hint: "Most audio resent after one reconnect", fmt: fmtS, calc: l => { const v = nums(l, "replay_max_s"); return { value: v.length ? Math.max(...v) : null, n: v.length }; } },
  { key: "focusWait", group: "saturation", label: "Text waited for its field", fmt: fmtPct, calc: l => share(completed(l), s => s.focus_wait_s != null) },
  { key: "micRecoveries", group: "saturation", label: "Mic recoveries", fmt: fmtInt, calc: l => ({ value: sum(nums(l, "mic_recoveries")), n: l.length }) },
  { key: "dropouts", group: "saturation", label: "Mic dropouts", fmt: fmtInt, calc: l => { const v = nums(l, "mic_dropouts"); return { value: v.length ? sum(v) : null, n: v.length }; } },
  { key: "renewals", group: "saturation", label: "Sign-in renewals", fmt: fmtInt, calc: l => ({ value: sum(nums(l, "auth_renewals")), n: l.length }) },
  { key: "rewritesPer100", group: "speech", label: "Rewrites per 100 words", hint: "Times the shown text changed words it had already shown, per 100 final words", better: "low", fmt: v => v == null ? "-" : v.toFixed(1), calc: l => { const v = completed(l).filter(s => s.rewrite_words != null && s.words > 0); const words = sum(nums(v, "words")); return { value: words ? 100 * sum(nums(v, "revisions")) / words : null, n: v.length }; }, win: "rewrites its text least often" },
  { key: "churn", group: "speech", label: "Words rewritten per 100", hint: "Words changed after they were shown, per 100 final words: how much the first result differed", better: "low", fmt: v => v == null ? "-" : v.toFixed(1), calc: l => { const v = completed(l).filter(s => s.rewrite_words != null && s.words > 0); const words = sum(nums(v, "words")); return { value: words ? 100 * sum(nums(v, "rewrite_words")) / words : null, n: v.length }; }, win: "changes the fewest words after showing them" },
  { key: "bigRewrites", group: "speech", label: "Large rewrites", hint: "Share of rewrites that changed 4 or more words at once", better: "low", fmt: fmtPct, calc: l => { const v = l.filter(s => s.rewrite_words != null); const all = sum(nums(v, "revisions")); return { value: all ? sum(nums(v, "rewrites_large")) / all : null, n: v.filter(s => s.revisions > 0).length }; }, win: "makes the fewest large rewrites" },
  { key: "maxRewrite", group: "speech", label: "Largest rewrite p95", hint: "Words changed by the biggest single rewrite in a dictation, p95", better: "low", fmt: v => v == null ? "-" : Math.round(v) + (Math.round(v) === 1 ? " word" : " words"), calc: l => { const v = nums(completed(l), "rewrite_max_words"); return { value: quantile(v, 0.95), n: v.length }; } },
  { key: "revisions", group: "speech", label: "Updates that rewrote", hint: "Share of text updates that changed shown words instead of only adding words", better: "low", fmt: fmtPct, calc: l => { const p = l.filter(s => s.partials > 0 && s.rewrite_words != null); const total = sum(nums(p, "partials")); return { value: total ? sum(nums(p, "revisions")) / total : null, n: p.length }; } },
  { key: "finalChange", group: "speech", label: "Final vs live text", hint: "Share of words that changed between the pill at release and the final text (average)", better: "low", fmt: fmtPct, calc: l => { const v = nums(completed(l), "final_change"); return { value: v.length ? sum(v) / v.length : null, n: v.length }; }, win: "shows live text closest to the final result" },
  { key: "wpm", group: "speech", label: "Words per minute", hint: "Median over dictations longer than 2 s", fmt: fmtInt, calc: l => { const v = completed(l).filter(s => s.audio_s > 2).map(s => s.words / (s.audio_s / 60)); return { value: quantile(v, 0.5), n: v.length }; } },
  { key: "peak", group: "speech", label: "Input peak (median)", fmt: fmtDb, calc: l => { const v = nums(l, "peak_dbfs"); return { value: quantile(v, 0.5), n: v.length }; } },
  { key: "rms", group: "speech", label: "Input loudness (median)", fmt: fmtDb, calc: l => { const v = nums(l, "rms_dbfs"); return { value: quantile(v, 0.5), n: v.length }; } },
  { key: "snr", group: "speech", label: "Signal to noise (median)", hint: "Speech level minus background level, from the loudest and quietest 10% of the audio (an estimate)", fmt: v => v == null ? "-" : v.toFixed(1) + " dB", calc: l => { const v = nums(l, "snr_db"); return { value: quantile(v, 0.5), n: v.length }; } },
  { key: "noiseFloor", group: "speech", label: "Background level (median)", hint: "Loudness of the quietest 10% of the audio", fmt: fmtDb, calc: l => { const v = nums(l, "noise_floor_dbfs"); return { value: quantile(v, 0.5), n: v.length }; } },
  { key: "clipping", group: "speech", label: "Clipped dictations", hint: "More than 0.1% of samples at full scale", fmt: fmtPct, calc: l => share(l.filter(s => s.clipped_ratio != null), s => s.clipped_ratio > 0.001) },
];
const GROUPS = { latency: "Latency", traffic: "Traffic", errors: "Errors", saturation: "Saturation", speech: "Accuracy and input" };
const signal = key => SIGNALS.find(s => s.key === key);
const NOISE = { low: "Low noise", moderate: "Some noise", high: "High noise", weak_input: "Weak input" };
const PALETTE = ["#a3e635", "#fb923c", "#c084fc", "#2dd4bf", "#60a5fa", "#f87171", "#facc15", "#e879f9"];
const DIMS = {
  provider: { label: "Provider", key: s => s.provider || "unknown", order: Object.keys(OBS_PROVIDERS) },
  model: { label: "Model", key: s => (OBS_PROVIDERS[s.provider]?.name || s.provider || "unknown") + " " + (s.model || "default") },
  mic: { label: "Microphone", key: s => s.mic_type || "unknown" },
  noise: { label: "Noise", key: s => s.noise || "unknown", order: Object.keys(NOISE), name: k => NOISE[k] || k },
  language: { label: "Language", key: s => s.language || "unknown" },
};
function dimKeys(dimKey, list) {
  const dim = DIMS[dimKey], counts = {};
  for (const s of list) { const k = dim.key(s); counts[k] = (counts[k] || 0) + 1; }
  return Object.keys(counts).sort((a, b) => dim.order ? (dim.order.indexOf(a) + 1 || 99) - (dim.order.indexOf(b) + 1 || 99) : counts[b] - counts[a]);
}
/// Splits dictations, and their connections, into groups along a dimension (provider, model,
/// microphone, noise, language). Names and colors of non-provider groups go into obs.meta.
function groupBy(dimKey, list, streams) {
  const dim = DIMS[dimKey], keyOf = new Map(list.map(s => [s.trace_id, dim.key(s)]));
  const providerColored = new Set();
  return dimKeys(dimKey, list).map((k, i) => {
    // A model keeps its provider's color; a second model of the same provider gets a palette color.
    const provider = dimKey === "model" ? list.find(s => dim.key(s) === k)?.provider : null;
    const own = provider && OBS_PROVIDERS[provider] && !providerColored.has(provider);
    if (own) providerColored.add(provider);
    if (dimKey !== "provider") obs.meta[k] = { name: dim.name ? dim.name(k) : k, color: own ? OBS_PROVIDERS[provider].color : PALETTE[i % PALETTE.length] };
    return { p: k, list: list.filter(s => dim.key(s) === k), streams: streams.filter(st => keyOf.get(st.trace_id) === k) };
  });
}

/// Ranks providers on one signal. Only providers with enough samples are ranked.
function rank(sig, groups) {
  const all = groups.map(g => ({ p: g.p, ...sig.calc(g.list, g.streams) })).filter(r => r.value != null);
  const ranked = all.filter(r => r.n >= OBS_MIN_N).sort((a, b) => sig.better === "low" ? a.value - b.value : b.value - a.value);
  let tie = false;
  if (ranked.length >= 2) {
    const [a, b] = ranked;
    tie = sig.fmt === fmtPct ? Math.abs(a.value - b.value) < 0.01 : Math.abs(a.value - b.value) / Math.max(Math.abs(a.value), Math.abs(b.value), 1e-9) < 0.05;
  }
  return { all, ranked, tie, best: ranked.length >= 2 && !tie ? ranked[0].p : null };
}

// --- Panels and charts ---
const panel = (title, body, opts = {}) =>
  '<div class="panel"' + (opts.id ? ' id="' + opts.id + '"' : '') + '><div class="panel-head"><h2>' + title + '</h2><div class="row">' +
  (opts.sub ? '<span class="muted mono">' + esc(opts.sub) + '</span>' : '') +
  (opts.sql ? '<button type="button" class="btn small" data-explore="' + esc(opts.sql) + '">SQL</button>' : '') +
  '</div></div>' + body + '</div>';

function timeBuckets() {
  const step = obs.range <= 1 ? 3600 : 86400, now = Date.now() / 1000;
  let start;
  if (step === 3600) start = Math.floor((now - 86400) / 3600) * 3600 + 3600;
  else { const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - obs.range + 1); start = d.getTime() / 1000; }
  const xs = [];
  for (let t = start; t <= now; t += step) xs.push(t);
  return { xs, step, index: t => Math.floor((t - start) / step) };
}
/// One series per provider: `fn` reduces the sessions (and connections) of each time bucket.
function providerSeries(groups, fn) {
  const b = timeBuckets();
  const series = groups.map(g => {
    const bins = b.xs.map(() => ({ list: [], streams: [] }));
    for (const s of g.list) { const i = b.index(s.t); if (bins[i]) bins[i].list.push(s); }
    for (const s of g.streams) { const i = b.index(s.t); if (bins[i]) bins[i].streams.push(s); }
    return { label: opName(g.p), color: opColor(g.p), values: bins.map(x => fn(x.list, x.streams)) };
  });
  return { xs: b.xs, step: b.step, series };
}
function chart(id, data, fmt, opts = {}) {
  obs.specs[id] = { ...data, fmt, ...opts };
  return '<div class="chart" id="chart-' + id + '"></div>';
}
function mountCharts() {
  obs.charts.forEach(c => c.destroy());
  obs.charts = [];
  for (const [id, sp] of Object.entries(obs.specs)) {
    const el = document.getElementById("chart-" + id);
    if (!el) continue;
    if (!sp.series.some(s => s.values.some(v => v != null))) { el.innerHTML = '<div class="muted mono empty-chart">NO DATA IN THIS RANGE</div>'; continue; }
    const axis = { stroke: "#8a8a8a", grid: { stroke: "#232323", width: 1 }, ticks: { stroke: "#2c2c2c", width: 1 }, font: "10px " + getComputedStyle(document.body).getPropertyValue("--mono") };
    obs.charts.push(new uPlot({
      width: Math.max(320, el.clientWidth), height: sp.height || 200,
      cursor: { points: { size: 7 } },
      series: [
        { value: (u, v) => v == null ? "-" : new Date(v * 1000).toLocaleString([], sp.step === 3600 ? { hour: "2-digit", minute: "2-digit" } : { month: "short", day: "numeric" }) },
        ...sp.series.map(s => ({ label: s.label, stroke: s.color, fill: sp.fill ? s.color + "1f" : undefined, width: 2, spanGaps: !sp.fill, points: { show: true, size: 5, fill: s.color }, value: (u, v) => v == null ? "-" : sp.fmt(v) })),
      ],
      axes: [axis, { ...axis, size: 70, values: (u, vals) => vals.map(v => sp.fmt(v)) }],
      scales: { x: { time: true }, y: { range: (u, min, max) => [0, max > 0 ? max * 1.12 : 1] } },
    }, [sp.xs, ...sp.series.map(s => s.values)], el));
  }
}

/// Every dictation as a dot on a log scale, with lines at the median and p95.
function stripSvg(groups, col) {
  const W = 1000, L = 110, R = 24, rowH = 36, H = groups.length * rowH + 28;
  const vals = groups.map(g => nums(completed(g.list), col).filter(v => v > 0));
  const all = vals.flat();
  if (!all.length) return '<div class="muted mono">NO DATA FOR THIS STAGE IN THIS RANGE</div>';
  const lo = Math.max(0.005, Math.min(...all) * 0.7), hi = Math.max(lo * 4, Math.max(...all) * 1.3);
  const x = v => L + (Math.log(Math.max(v, lo) / lo) / Math.log(hi / lo)) * (W - L - R);
  let svg = '<svg class="strip" viewBox="0 0 ' + W + ' ' + H + '">';
  for (const t of [0.01, 0.02, 0.05, 0.1, 0.15, 0.25, 0.35, 0.5, 0.75, 1, 1.5, 2.5, 5, 10, 30, 60, 120, 300]) {
    if (t < lo || t > hi) continue;
    svg += '<line x1="' + x(t) + '" x2="' + x(t) + '" y1="0" y2="' + (H - 18) + '" stroke="#262626"/><text x="' + x(t) + '" y="' + (H - 4) + '" text-anchor="middle">' + fmtS(t) + '</text>';
  }
  groups.forEach((g, i) => {
    const y = i * rowH + rowH / 2, v = vals[i], med = quantile(v, 0.5), p95 = quantile(v, 0.95);
    svg += '<text x="0" y="' + (y + 4) + '" class="lbl">' + esc(opName(g.p)) + '</text>';
    v.forEach((val, j) => { svg += '<circle cx="' + x(val) + '" cy="' + (y + ((j * 7919) % 21 - 10)) + '" r="3" fill="' + opColor(g.p) + '" opacity="0.55"><title>' + fmtS(val) + '</title></circle>'; });
    if (med != null) svg += '<line x1="' + x(med) + '" x2="' + x(med) + '" y1="' + (y - 14) + '" y2="' + (y + 14) + '" stroke="#fff" stroke-width="2"><title>median ' + fmtS(med) + '</title></line>';
    if (p95 != null) svg += '<line x1="' + x(p95) + '" x2="' + x(p95) + '" y1="' + (y - 14) + '" y2="' + (y + 14) + '" stroke="#fff" stroke-dasharray="3 3"><title>p95 ' + fmtS(p95) + '</title></line>';
  });
  return svg + '</svg>';
}

/// Providers as columns, signals as rows, the best ranked value marked.
function scoreTable(groups, keys) {
  const head = '<tr><th>Signal</th>' + groups.map(g => '<th>' + opLabel(g.p) + '</th>').join("") + '</tr>';
  let body = "", lastGroup = null;
  for (const sig of keys.map(signal)) {
    if (keys.length > 8 && sig.group !== lastGroup) { body += '<tr class="group"><td colspan="' + (groups.length + 1) + '">' + GROUPS[sig.group] + '</td></tr>'; lastGroup = sig.group; }
    const r = sig.better ? rank(sig, groups) : null;
    body += '<tr><td title="' + esc(sig.hint || "") + '">' + esc(sig.label) + (sig.hint ? ' <span class="info">?</span>' : '') + '</td>' + groups.map(g => {
      const v = sig.calc(g.list, g.streams);
      if (v.value == null) return '<td class="muted">-</td>';
      const best = r && r.best === g.p, thin = sig.better && v.n < OBS_MIN_N;
      return '<td class="' + (best ? "best" : "") + (thin ? " thin" : "") + '" title="' + (thin ? "Fewer than " + OBS_MIN_N + " samples: not ranked" : "") + '">' +
        sig.fmt(v.value) + (v.p95 != null ? '<span class="n">p95 ' + sig.fmt(v.p95) + '</span>' : '') + '<span class="n">n=' + v.n + '</span></td>';
    }).join("") + '</tr>';
  }
  return '<div class="table-scroll"><table class="grid score"><thead>' + head + '</thead><tbody>' + body + '</tbody></table></div>';
}

function takeawaysHtml(groups) {
  if (groups.length < 2) return '<div class="muted">Choose at least two providers with dictations in this range to compare them.</div>';
  const wins = {};
  const items = SIGNALS.filter(s => s.win).map(sig => {
    const r = rank(sig, groups);
    if (r.ranked.length < 2) {
      return r.all.length ? '<li class="muted"><strong>' + esc(sig.label) + ':</strong> not enough data yet (needs ' + OBS_MIN_N + ' per provider)' +
        ' <span class="vals">' + r.all.map(x => esc(opName(x.p)) + " " + sig.fmt(x.value) + " (n=" + x.n + ")").join(", ") + '</span></li>' : "";
    }
    const vals = r.ranked.map(x => opDot(x.p) + esc(opName(x.p)) + ' ' + sig.fmt(x.value)).join(' <span class="muted">/</span> ');
    if (r.tie) return '<li><strong>' + esc(sig.label) + ':</strong> ' + esc(opName(r.ranked[0].p)) + ' and ' + esc(opName(r.ranked[1].p)) + ' are even <span class="vals">' + vals + '</span></li>';
    wins[r.best] = (wins[r.best] || 0) + 1;
    return '<li><strong>' + opLabel(r.best) + '</strong> ' + esc(sig.win) + ' <span class="vals">' + vals + '</span></li>';
  }).join("");
  const order = Object.entries(wins).sort((a, b) => b[1] - a[1]);
  const total = SIGNALS.filter(s => s.win).length;
  const lead = order.length ? '<div class="verdict">' + opLabel(order[0][0]) + ' leads ' + order[0][1] + ' of ' + total + ' categories' +
    (order.length > 1 ? '<span class="muted">, then ' + order.slice(1).map(([p, n]) => esc(opName(p)) + ' ' + n).join(", ") + '</span>' : '') + '</div>' : '';
  return lead + '<ul class="takeaways">' + items + '</ul><div class="muted small">Latency compares medians of completed dictations. A provider needs ' + OBS_MIN_N +
    ' samples in the range to be ranked; differences under 5% (or 1 point for rates) count as even.</div>';
}

// --- Pages ---
function renderObsPage() {
  obs.specs = {};
  obs.meta = {};
  const list = obsSel(), streams = obsSelStreams(), groups = groupBy(obs.dim, list, streams);
  document.getElementById("obs-subtitle").textContent = list.length.toLocaleString() + " DICTATIONS, " + streams.length.toLocaleString() +
    " CONNECTIONS IN RANGE // LOCAL telemetry.sqlite";
  const el = document.getElementById("obs-page");
  const pages = { overview: pageOverview, latency: pageLatency, traffic: pageTraffic, errors: pageErrors, saturation: pageSaturation, accuracy: pageAccuracy, traces: pageTraces, metrics: pageMetrics, query: pageQuery };
  if (obs.page !== "query" || !document.getElementById("q-sql")) el.innerHTML = pages[obs.page](groups, list, streams);
  mountCharts();
  if (obs.page === "traces" && obs.trace) obsOpenTrace(obs.trace, false);
  if (obs.page === "metrics") obsMetricRender();
}

function goldenCards(groups) {
  return '<div class="pcards">' + groups.map(g => {
    const v = k => { const sig = signal(k); return sig.fmt(sig.calc(g.list, g.streams).value); };
    const rel = signal("release").calc(g.list, g.streams);
    return '<div class="pcard" style="--pc:' + opColor(g.p) + '"><div class="label">' + opLabel(g.p) + '</div>' +
      '<div class="big">' + fmtS(rel.value) + '<small>RELEASE TO TEXT P50</small></div><dl>' +
      '<dt>Latency p95</dt><dd>' + fmtS(rel.p95) + '</dd>' +
      '<dt>Traffic</dt><dd>' + v("dictations") + ' / ' + v("audio") + '</dd>' +
      '<dt>Errors</dt><dd>' + v("success") + ' ok, ' + v("connErrors") + ' conn.</dd>' +
      '<dt>Saturation</dt><dd>' + v("reconnects") + ' reconn./100</dd>' +
      '<dt>First words</dt><dd>' + v("first") + '</dd></dl></div>';
  }).join("") + '</div>';
}

function pageOverview(groups) {
  const keys = SIGNALS.map(s => s.key);
  return panel('TAKEAWAYS <span class="accent">BY CATEGORY</span>', takeawaysHtml(groups)) +
    panel('GOLDEN <span class="accent">SIGNALS</span>', goldenCards(groups), { sub: "LATENCY, TRAFFIC, ERRORS, SATURATION" }) +
    '<div class="charts-2">' +
    panel("RELEASE TO TEXT P50", chart("ov-lat", providerSeries(groups, l => quantile(nums(completed(l), "release_s"), 0.5)), fmtS)) +
    panel("SUCCESS RATE", chart("ov-err", providerSeries(groups, l => share(decided(l), s => s.outcome === "completed").value), fmtPct)) +
    panel("DICTATIONS", chart("ov-traffic", providerSeries(groups, l => l.length || null), fmtInt, { fill: true })) +
    panel("RECONNECTS PER 100", chart("ov-sat", providerSeries(groups, l => signal("reconnects").calc(l).value), v => v.toFixed(0))) +
    '</div>' +
    panel('PROVIDER <span class="accent">SCORECARD</span>', scoreTable(groups, keys), { sub: "BEST RANKED VALUE IN YELLOW", sql: SQL_SESSIONS.replace("?1 * 1e9", "(unixepoch() - " + obs.range * 86400 + ") * 1e9") });
}

const STAGES = ["release", "finish", "first", "connect", "typing"];
const STAGE_COL = { release: "release_s", finish: "finish_s", first: "first_text_s", connect: "connect_s", typing: "typing_s" };
function pageLatency(groups) {
  const pcts = [0.5, 0.9, 0.95, 0.99];
  let rows = "";
  for (const key of STAGES) {
    const sig = signal(key), r = rank(sig, groups);
    groups.forEach((g, i) => {
      const v = nums(completed(g.list), STAGE_COL[key]);
      rows += '<tr' + (i === 0 ? ' class="first"' : '') + '><td title="' + esc(sig.hint) + '">' + (i === 0 ? esc(sig.label) : '') + '</td><td class="left">' + opLabel(g.p) + '</td><td>' + v.length + '</td>' +
        pcts.map((p, j) => '<td class="' + (j === 0 && r.best === g.p ? "best" : "") + '">' + fmtS(quantile(v, p)) + '</td>').join("") + '<td>' + fmtS(v.length ? Math.max(...v) : null) + '</td></tr>';
    });
  }
  const sig = signal(obs.latencyStage);
  const seg = '<div class="seg" data-obs-stage>' + STAGES.map(k => '<button type="button" data-stage="' + k + '"' + (k === obs.latencyStage ? ' class="active"' : '') + '>' + esc(signal(k).label) + '</button>').join("") + '</div>' +
    '<div class="seg" data-obs-pct>' + [0.5, 0.95, 0.99].map(p => '<button type="button" data-pct="' + p + '"' + (p === obs.latencyPct ? ' class="active"' : '') + '>P' + Math.round(p * 100) + '</button>').join("") + '</div>';
  const failed = groups.map(g => { const v = nums(g.list.filter(s => s.outcome === "failed"), "duration_s"); return '<tr><td class="left">' + opLabel(g.p) + '</td><td>' + v.length + '</td><td>' + fmtS(quantile(v, 0.5)) + '</td><td>' + fmtS(quantile(v, 0.95)) + '</td></tr>'; }).join("");
  return '<div class="toolbar">' + seg + '</div>' +
    panel(esc(sig.label.toUpperCase()) + ' <span class="accent">P' + Math.round(obs.latencyPct * 100) + ' OVER TIME</span>', chart("lat-ts", providerSeries(groups, l => quantile(nums(completed(l), STAGE_COL[obs.latencyStage]), obs.latencyPct)), fmtS, { height: 240 }), { sub: sig.hint.toUpperCase() }) +
    panel(esc(sig.label.toUpperCase()) + ' <span class="accent">DISTRIBUTION</span>', stripSvg(groups, STAGE_COL[obs.latencyStage]), { sub: "EVERY DICTATION, LOG SCALE, LINES AT P50 AND P95" }) +
    panel('PERCENTILES BY <span class="accent">STAGE</span>', '<div class="table-scroll"><table class="grid"><thead><tr><th>Stage</th><th class="left">Provider</th><th>n</th><th>p50</th><th>p90</th><th>p95</th><th>p99</th><th>max</th></tr></thead><tbody>' + rows + '</tbody></table></div>', { sub: "COMPLETED DICTATIONS, FASTEST P50 IN YELLOW" }) +
    panel('ERROR <span class="accent">LATENCY</span>', '<div class="table-scroll"><table class="grid"><thead><tr><th class="left">Provider</th><th>Failed</th><th>p50 to fail</th><th>p95 to fail</th></tr></thead><tbody>' + failed + '</tbody></table></div>', { sub: "A SLOW ERROR IS WORSE THAN A FAST ONE" });
}

function breakdown(groups, col, title, top = 8) {
  const keys = {};
  for (const g of groups) for (const s of g.list) { const k = s[col] || "unknown"; keys[k] = (keys[k] || 0) + 1; }
  const natural = col === "noise" ? Object.keys(NOISE) : null, name = k => col === "noise" ? (NOISE[k] || k) : k;
  const order = Object.entries(keys).sort((a, b) => natural ? (natural.indexOf(a[0]) + 1 || 99) - (natural.indexOf(b[0]) + 1 || 99) : b[1] - a[1]).slice(0, top).map(x => x[0]);
  if (!order.length) return panel(title, '<div class="muted mono">NO DATA</div>');
  return panel(title, '<div class="table-scroll"><table class="grid"><thead><tr><th class="left">' + esc(col.replace(/_/g, " ")) + '</th>' + groups.map(g => '<th>' + opLabel(g.p) + '</th>').join("") + '</tr></thead><tbody>' +
    order.map(k => '<tr><td class="left">' + esc(name(k)) + '</td>' + groups.map(g => { const n = g.list.filter(s => (s[col] || "unknown") === k).length; return '<td>' + (n ? fmtInt(n) + '<span class="n">' + fmtPct(n / g.list.length) + '</span>' : '-') + '</td>'; }).join("") + '</tr>').join("") +
    '</tbody></table></div>');
}

function pageTraffic(groups) {
  return '<div class="charts-2">' +
    panel("DICTATIONS", chart("tr-n", providerSeries(groups, l => l.length || null), fmtInt, { fill: true })) +
    panel("AUDIO MINUTES", chart("tr-audio", providerSeries(groups, l => l.length ? sum(nums(l, "audio_s")) / 60 : null), v => v.toFixed(1), { fill: true })) +
    panel("CONNECTIONS", chart("tr-conn", providerSeries(groups, (l, st) => st.length || null), fmtInt, { fill: true })) +
    panel("WORDS", chart("tr-words", providerSeries(groups, l => l.length ? sum(nums(l, "words")) : null), fmtInt, { fill: true })) +
    '</div>' + panel('TRAFFIC <span class="accent">TOTALS</span>', scoreTable(groups, ["dictations", "audio", "connections", "words", "wpm"])) +
    '<div class="charts-2">' + breakdown(groups, "trigger_mode", "TRIGGER MODE") + breakdown(groups, "language", "LANGUAGE") +
    breakdown(groups, "model", "MODEL") + breakdown(groups, "mic_type", "MICROPHONE") + '</div>' + breakdown(groups, "target_app", "TARGET APPS", 12);
}

const OUTCOMES = [
  ["clean", "Clean", "#22c55e", s => s.outcome === "completed" && s.attempts <= 1],
  ["recovered", "Recovered after retry", "#a3e635", s => s.outcome === "completed" && s.attempts > 1],
  ["kept", "Failed, text kept", "#fb923c", s => s.outcome === "failed" && Number(s.characters) > 0],
  ["lost", "Failed, no text", "#ef4444", s => s.outcome === "failed" && !Number(s.characters)],
  ["cancelled", "Cancelled", "#555", s => s.outcome === "cancelled"],
];
function outcomesHtml(groups) {
  return groups.map(g => {
    const n = g.list.length || 1;
    return '<div class="stack-row"><span class="stack-label">' + opLabel(g.p) + '</span><div class="stack">' + OUTCOMES.map(([k, label, color, pred]) => {
      const c = g.list.filter(pred).length;
      return c ? '<div style="width:' + (100 * c / n) + '%;background:' + color + '" title="' + esc(label) + ': ' + c + ' (' + fmtPct(c / n) + ')"></div>' : '';
    }).join("") + '</div><span class="mono small">' + fmtInt(g.list.length) + '</span></div>';
  }).join("") + '<div class="legend-row">' + OUTCOMES.map(([k, label, color]) => '<span><span class="dot" style="background:' + color + '"></span>' + esc(label) + '</span>').join("") + '</div>';
}

function errorTable(list, streams) {
  const groups = new Map();
  const add = (p, level, type, t, detail, trace) => {
    const k = p + "|" + level + "|" + type;
    const g = groups.get(k) || { p, level, type, n: 0, last: 0, details: new Set(), trace: null };
    g.n++;
    if (t >= g.last) { g.last = t; g.trace = trace; }
    if (detail) g.details.add(detail);
    groups.set(k, g);
  };
  for (const s of list) if (s.error_type) add(s.provider, "dictation", s.error_type, s.t, s.error_message, s.trace_id);
  for (const s of streams) if (s.error_type) add(s.provider, "connection", s.error_type, s.t, [s.http_status && "HTTP " + s.http_status, s.ws_close_code && "WS " + s.ws_close_code, s.error_message].filter(Boolean).join(" "), s.trace_id);
  for (const s of list) if (s.auth_failures > 0) add(s.provider, "sign-in", "renewal_failed", s.t, "", s.trace_id);
  const rows = [...groups.values()].sort((a, b) => b.n - a.n || b.last - a.last);
  if (!rows.length) return '<div class="muted mono">NO ERRORS IN THIS RANGE</div>';
  return '<div class="table-scroll"><table class="grid"><thead><tr><th class="left">Provider</th><th class="left">Level</th><th class="left">Error type</th><th>Count</th><th>Last seen</th><th class="left">Details</th><th>Trace</th></tr></thead><tbody>' +
    rows.map(g => '<tr><td class="left">' + opLabel(g.p) + '</td><td class="left">' + esc(g.level) + '</td><td class="left bad">' + esc(g.type) + '</td><td>' + fmtInt(g.n) + '</td><td>' + esc(fmtWhen(g.last)) + '</td>' +
      '<td class="left muted wrap">' + esc([...g.details].slice(0, 3).join("; ").slice(0, 160)) + '</td><td><button type="button" class="btn small" data-trace="' + esc(g.trace) + '">Open</button></td></tr>').join("") + '</tbody></table></div>';
}

function pageErrors(groups, list, streams) {
  const failed = list.filter(s => s.outcome === "failed" || s.attempts > 1).slice(0, 30);
  return panel('ERROR <span class="accent">SIGNALS</span>', scoreTable(groups, ["success", "clean", "connErrors", "empty", "errorLatency"])) +
    '<div class="charts-2">' +
    panel("SUCCESS RATE", chart("er-success", providerSeries(groups, l => share(decided(l), s => s.outcome === "completed").value), fmtPct)) +
    panel("CONNECTION ERROR RATE", chart("er-conn", providerSeries(groups, (l, st) => share(st, s => !!s.error_type).value), fmtPct)) +
    '</div>' +
    panel('OUTCOMES BY <span class="accent">PROVIDER</span>', outcomesHtml(groups), { sub: "NEVER LOSE TEXT: RED MEANS NOTHING COULD BE INSERTED" }) +
    panel('ERRORS BY <span class="accent">TYPE</span>', errorTable(list, streams), { sub: "DICTATION, CONNECTION, AND SIGN-IN LEVEL", sql: "SELECT provider, error_type, http_status, ws_close_code, count(*) AS n, max(trace_id) AS example FROM streams WHERE error_type IS NOT NULL GROUP BY 1, 2, 3, 4 ORDER BY n DESC" }) +
    panel('FAILED OR RETRIED <span class="accent">DICTATIONS</span>', sessionTable(failed));
}

function pageSaturation(groups) {
  return panel('SATURATION <span class="accent">SIGNALS</span>', scoreTable(groups, ["backlog", "reconnects", "replay", "focusWait", "micRecoveries", "dropouts", "renewals"]),
    { sub: "HOW CLOSE THE CLIENT IS TO FALLING BEHIND" }) +
    '<div class="charts-2">' +
    panel("SEND BACKLOG P95", chart("sa-backlog", providerSeries(groups, l => quantile(nums(l, "backlog_max_s"), 0.95)), fmtS)) +
    panel("RECONNECTS PER 100", chart("sa-reconn", providerSeries(groups, l => signal("reconnects").calc(l).value), v => v.toFixed(0))) +
    panel("FOCUS WAIT P95", chart("sa-wait", providerSeries(groups, l => quantile(nums(l, "focus_wait_s"), 0.95)), fmtS)) +
    panel("MIC DROPOUTS", chart("sa-drop", providerSeries(groups, l => { const v = nums(l, "mic_dropouts"); return v.length ? sum(v) : null; }), fmtInt)) +
    '</div>' +
    '<div class="panel note"><strong>Reading saturation for a client app.</strong> The send backlog is audio captured but not yet sent; it grows while the connection is down and must be replayed. ' +
    'Reconnects and replays show a flaky network or provider. Focus waits are finished text waiting for its field. Mic dropouts are gaps in the audio the device delivered.</div>';
}

const REWRITE_SIZES = [["rewrites_small", "1 word", "#a3e635"], ["rewrites_medium", "2 to 3 words", "#fb923c"], ["rewrites_large", "4 or more", "#ef4444"]];
function rewriteSizesHtml(groups) {
  return groups.map(g => {
    const v = g.list.filter(s => s.rewrite_words != null), all = sum(nums(v, "revisions"));
    const per100 = signal("rewritesPer100").calc(g.list).value;
    return '<div class="stack-row"><span class="stack-label">' + opLabel(g.p) + '</span><div class="stack">' + (all ? REWRITE_SIZES.map(([col, label, color]) => {
      const c = sum(nums(v, col));
      return c ? '<div style="width:' + (100 * c / all) + '%;background:' + color + '" title="' + esc(label) + ': ' + c + ' (' + fmtPct(c / all) + ')"></div>' : '';
    }).join("") : '') + '</div><span class="mono small">' + (per100 == null ? "-" : per100.toFixed(1) + "/100w") + '</span></div>';
  }).join("") + '<div class="legend-row">' + REWRITE_SIZES.map(([, label, color]) => '<span><span class="dot" style="background:' + color + '"></span>' + esc(label) + '</span>').join("") +
    '<span>bar: share of rewrites by size; right: rewrites per 100 final words</span></div>';
}

/// Rows are the current groups, columns a second dimension, cells one signal: for example
/// providers against noise levels for words rewritten.
function crossTable(groups, colDim, sigKey) {
  const sig = signal(sigKey), dim = DIMS[colDim], cols = dimKeys(colDim, groups.flatMap(g => g.list));
  const colName = k => dim.name ? dim.name(k) : k;
  const cells = groups.map(g => cols.map(c => {
    const list = g.list.filter(s => dim.key(s) === c), ids = new Set(list.map(s => s.trace_id));
    return sig.calc(list, g.streams.filter(st => ids.has(st.trace_id)));
  }));
  const best = cols.map((c, j) => {
    const ranked = cells.map((row, i) => ({ i, ...row[j] })).filter(x => x.value != null && x.n >= OBS_MIN_N);
    if (!sig.better || ranked.length < 2) return -1;
    ranked.sort((a, b) => sig.better === "low" ? a.value - b.value : b.value - a.value);
    return ranked[0].i;
  });
  return '<div class="table-scroll"><table class="grid"><thead><tr><th class="left">' + esc(DIMS[obs.dim].label) + '</th>' + cols.map(c => '<th>' + esc(colName(c)) + '</th>').join("") + '<th>All</th></tr></thead><tbody>' +
    groups.map((g, i) => '<tr><td class="left">' + opLabel(g.p) + '</td>' + cells[i].map((v, j) => v.value == null ? '<td class="muted">-</td>' :
      '<td class="' + (best[j] === i ? "best" : "") + (sig.better && v.n < OBS_MIN_N ? " thin" : "") + '">' + sig.fmt(v.value) + '<span class="n">n=' + v.n + '</span></td>').join("") +
      (() => { const v = sig.calc(g.list, g.streams); return '<td>' + sig.fmt(v.value) + '<span class="n">n=' + v.n + '</span></td>'; })() + '</tr>').join("") + '</tbody></table></div>';
}

function pageAccuracy(groups) {
  const m = obs.matrix, opt = (v, cur, label) => '<option value="' + esc(v) + '"' + (v === cur ? " selected" : "") + '>' + esc(label) + '</option>';
  const controls = '<div class="row"><span class="muted mono">SIGNAL</span><select data-matrix="signal">' +
    SIGNALS.filter(x => x.calc).map(x => opt(x.key, m.signal, GROUPS[x.group] + ": " + x.label)).join("") + '</select><span class="muted mono">ACROSS</span><select data-matrix="col">' +
    Object.entries(DIMS).filter(([k]) => k !== obs.dim).map(([k, d]) => opt(k, m.col, d.label)).join("") + '</select></div>';
  return panel('REWRITES AND <span class="accent">ACCURACY</span>', scoreTable(groups, ["rewritesPer100", "churn", "bigRewrites", "maxRewrite", "revisions", "finalChange", "empty", "first"]),
      { sub: "HOW MUCH THE TEXT CHANGES AFTER IT IS SHOWN" }) +
    panel('REWRITE <span class="accent">SIZE</span>', rewriteSizesHtml(groups), { sub: "SMALL FIXES OR BIG CHANGES" }) +
    '<div class="panel"><div class="panel-head"><h2>BREAKDOWN <span class="accent">' + esc(DIMS[obs.dim].label.toUpperCase()) + ' x ' + esc((DIMS[m.col] || {}).label?.toUpperCase() || "") + '</span></h2>' + controls + '</div>' +
      crossTable(groups, m.col, m.signal) + '<div class="muted small">Best ranked value per column in yellow; cells with fewer than ' + OBS_MIN_N + ' dictations are dimmed and not ranked.</div></div>' +
    '<div class="charts-2">' +
    panel("REWRITES PER 100 WORDS", chart("ac-rate", providerSeries(groups, l => signal("rewritesPer100").calc(l).value), v => v.toFixed(1))) +
    panel("WORDS REWRITTEN PER 100", chart("ac-churn", providerSeries(groups, l => signal("churn").calc(l).value), v => v.toFixed(1))) +
    panel("LARGE REWRITES", chart("ac-large", providerSeries(groups, l => signal("bigRewrites").calc(l).value), fmtPct)) +
    panel("FINAL VS LIVE TEXT", chart("ac-change", providerSeries(groups, l => signal("finalChange").calc(l).value), fmtPct)) +
    '</div>' +
    panel('INPUT AND <span class="accent">NOISE</span>', scoreTable(groups, ["snr", "noiseFloor", "peak", "rms", "clipping", "wpm"]), { sub: "THE SAME VOICE THROUGH DIFFERENT MICROPHONES AND ROOMS" }) +
    '<div class="charts-2">' + breakdown(groups, "noise", "NOISE LEVEL") + breakdown(groups, "mic_type", "MICROPHONE") + '</div>' +
    '<div class="panel note"><strong>How to read this.</strong> A rewrite is any time the shown text changed words it had already shown, whether the provider revised its live text or its final ' +
    'result differed; case and punctuation are ignored. Words rewritten per 100 shows how far first results were from what the provider settled on, and the size bar shows whether those were ' +
    'one-word fixes or big changes. Without a reference transcript this is a proxy for accuracy, not a word error rate. Noise levels come from the gap between your speech and the quietest ' +
    'tenth of the audio: low is 30 dB or more, some is 20 to 30 dB, high is under 20 dB, and weak input means the speech itself was quieter than -50 dBFS. Compare by Model, Microphone, or Noise ' +
    'at the top to regroup every page.</div>';
}

// --- Traces ---
function sessionTable(rows) {
  if (!rows.length) return '<div class="muted mono">NO DICTATIONS MATCH</div>';
  return '<div class="table-scroll"><table class="grid"><thead><tr><th class="left">Time</th><th class="left">Provider</th><th class="left">Outcome</th><th>Audio</th><th>Connect</th><th>First words</th><th>Release to text</th><th>Total</th><th>Attempts</th><th>Rewrites</th><th class="left">Input</th><th>Words</th></tr></thead><tbody>' +
    rows.map(s => '<tr class="click' + (s.trace_id === obs.trace ? ' sel' : '') + '" data-trace="' + esc(s.trace_id) + '"><td class="left">' + esc(fmtWhen(s.t)) + '</td>' +
      '<td class="left">' + opLabel(s.provider) + (s.model ? '<span class="n">' + esc(s.model) + '</span>' : '') + '</td>' +
      '<td class="left ' + (s.outcome === "failed" ? "bad" : s.outcome === "completed" ? "good" : "muted") + '">' + esc(s.outcome) + (s.error_type ? '<span class="n">' + esc(s.error_type) + '</span>' : '') + '</td>' +
      '<td>' + fmtS(s.audio_s) + '</td><td>' + fmtS(s.connect_s) + '</td><td>' + fmtS(s.first_text_s) + '</td><td>' + fmtS(s.release_s) + '</td><td>' + fmtS(s.duration_s) + '</td>' +
      '<td class="' + (s.attempts > 1 ? "warn" : "") + '">' + s.attempts + '</td>' +
      '<td>' + (s.rewrite_words == null ? '-' : fmtInt(s.revisions) + '<span class="n">' + fmtInt(s.rewrite_words) + ' words, max ' + fmtInt(s.rewrite_max_words) + '</span>') + '</td>' +
      '<td class="left">' + esc(s.mic_type || "-") + '<span class="n">' + esc(NOISE[s.noise] || s.noise || "") + (s.snr_db != null ? " " + Number(s.snr_db).toFixed(0) + " dB" : "") + '</span></td>' +
      '<td>' + fmtInt(s.words) + '</td></tr>').join("") + '</tbody></table></div>';
}

function pageTraces(groups, list) {
  const f = obs.traceFilter, text = f.text.trim().toLowerCase();
  const rows = list.filter(s => (f.outcome === "all" || (f.outcome === "retried" ? s.attempts > 1 : s.outcome === f.outcome)) &&
    (s.duration_s || 0) >= f.minSeconds && (!text || [s.trace_id, s.error_type, s.model, s.target_app, s.mic_type, NOISE[s.noise] || s.noise].some(v => v && String(v).toLowerCase().includes(text)))).slice(0, 200);
  const filters = '<div class="toolbar"><div class="row">' +
    '<div class="seg" data-obs-outcome>' + ["all", "completed", "failed", "retried", "cancelled"].map(o => '<button type="button" data-outcome="' + o + '"' + (o === f.outcome ? ' class="active"' : '') + '>' + o + '</button>').join("") + '</div>' +
    '<input type="number" id="tr-min" min="0" step="0.5" placeholder="Min seconds" value="' + (f.minSeconds || "") + '" title="Minimum total duration in seconds">' +
    '<input type="text" id="tr-text" placeholder="Trace ID, error type, model, app" value="' + esc(f.text) + '"></div>' +
    '<span class="muted mono">' + rows.length + ' SHOWN</span></div>';
  return filters + '<div class="panel"><div id="trace-detail"></div>' + sessionTable(rows) + '</div>';
}

const SPAN_LABEL = { "sayit2.dictation": "dictation", "sayit2.stream": "connection", "sayit2.auth.renew": "sign-in renewal", "sayit2.insert": "typing" };
const MILESTONES = { mic_first_audio: "Mic live", connected: "Connected", audio_started: "Audio sending", first_message: "Provider ready", first_text: "First words",
  recording_stopped: "Key released", mic_stopped: "Mic closed", finish_requested: "Final requested", retry_scheduled: "Retry scheduled", mic_recovery: "Mic recovered", mic_silent: "Mic silent" };

async function obsOpenTrace(traceId, scroll = true) {
  obs.trace = traceId;
  const box = document.getElementById("trace-detail");
  if (!box) { obs.page = "traces"; obsSetPage("traces"); return; }
  document.querySelectorAll("tr[data-trace]").forEach(r => r.classList.toggle("sel", r.dataset.trace === traceId));
  try {
    const [sp, ev, lg] = await Promise.all([
      obsQuery("SELECT * FROM spans WHERE trace_id = ?1 ORDER BY start_ns", [traceId]),
      obsQuery("SELECT * FROM span_events WHERE trace_id = ?1 ORDER BY time_ns", [traceId]),
      obsQuery("SELECT time_ns, severity_text, event_name, body, span_id FROM logs WHERE trace_id = ?1 ORDER BY time_ns", [traceId]),
    ]);
    const spans = obsRows(sp).map(s => ({ ...s, attrs: JSON.parse(s.attributes || "{}"), start: s.start_ns / 1e9, end: s.end_ns / 1e9 }));
    const events = obsRows(ev).map(e => ({ ...e, t: e.time_ns / 1e9, attrs: JSON.parse(e.attributes || "{}") }));
    const logs = obsRows(lg);
    if (obs.trace !== traceId) return;
    box.innerHTML = traceHtml(traceId, spans, events, logs);
    box.className = "trace-open";
    if (scroll) box.scrollIntoView({ behavior: "smooth", block: "start" });
  } catch (e) {
    box.innerHTML = '<div class="bad mono">' + esc(e.message) + '</div>';
  }
}

function traceHtml(traceId, spans, events, logs) {
  const root = spans.find(s => !s.parent_span_id) || spans[0];
  if (!root) return '<div class="muted mono">TRACE NOT FOUND (OLDER THAN ' + 90 + ' DAYS?)</div>';
  const t0 = root.start, total = Math.max(...spans.map(s => s.end), ...events.map(e => e.t)) - t0 || 1;
  const pos = t => ((t - t0) / total) * 100;
  const provider = root.attrs["gen_ai.provider.name"];
  const flow = events.filter(e => MILESTONES[e.name]).map(e => '<span class="chip" title="' + esc(e.name) + '">' + esc(MILESTONES[e.name]) + ' <b>+' + fmtS(e.t - t0) + '</b></span>');
  const typing = spans.find(s => s.name === "sayit2.insert");
  if (typing) flow.push('<span class="chip">Text typed <b>+' + fmtS(typing.end - t0) + '</b></span>');
  const rows = spans.map(s => {
    const own = events.filter(e => e.span_id === s.span_id);
    const label = (SPAN_LABEL[s.name] || s.name) + (s.name === "sayit2.stream" ? " #" + (s.attrs["sayit2.stream.attempt"] || 1) : "");
    const err = s.status_code === 2;
    return '<div class="wf-row' + (s.span_id === obs.traceSpan ? ' sel' : '') + '" data-span="' + esc(s.span_id) + '"><span class="' + (s.parent_span_id ? "child" : "") + '">' + esc(label) + '</span><div class="wf-track">' +
      '<div class="wf-bar' + (err ? ' err' : '') + '" style="background:' + (err ? "" : opColor(provider)) + ';left:' + pos(s.start) + '%;width:' + Math.max(0.4, pos(s.end) - pos(s.start)) + '%"></div>' +
      own.map(e => '<div class="wf-tick" style="left:' + pos(e.t) + '%" title="' + esc(e.name + " +" + fmtS(e.t - t0)) + '"></div>').join("") +
      '</div><span class="mono">' + fmtS(s.end - s.start) + '</span></div>';
  }).join("");
  const sel = spans.find(s => s.span_id === obs.traceSpan) || root;
  const attrs = Object.entries(sel.attrs).sort().map(([k, v]) => '<tr><td class="left">' + esc(k) + '</td><td class="left wrap">' + esc(typeof v === "number" && !Number.isInteger(v) ? String(Number(v.toPrecision(4))) : String(v)) + '</td></tr>').join("");
  const ownEvents = events.filter(e => e.span_id === sel.span_id).map(e => '<tr><td class="left">+' + fmtS(e.t - t0) + '</td><td class="left">' + esc(e.name) + (Object.keys(e.attrs).length ? ' <span class="muted">' + esc(JSON.stringify(e.attrs)) + '</span>' : '') + '</td></tr>').join("");
  return '<div class="panel-head"><div class="day-detail-title">' + opLabel(provider) + ' ' + esc(root.attrs["gen_ai.request.model"] || "") + ' // ' + esc(fmtWhen(t0)) + '</div>' +
    '<div class="row"><span class="muted mono small">' + esc(traceId) + '</span><button type="button" class="btn small" data-close-trace>Close</button></div></div>' +
    '<div class="flow">' + flow.join('<span class="arrow">&rarr;</span>') + '</div>' + rows +
    '<div class="grid-2 trace-info"><div><h3>' + esc((SPAN_LABEL[sel.name] || sel.name).toUpperCase()) + ' ATTRIBUTES' + (sel.status_message ? ' <span class="bad">' + esc(sel.status_message) + '</span>' : '') + '</h3>' +
    '<table class="grid kv"><tbody>' + attrs + '</tbody></table>' + (ownEvents ? '<h3>EVENTS</h3><table class="grid kv"><tbody>' + ownEvents + '</tbody></table>' : '') + '</div>' +
    '<div><h3>LOGS</h3><div class="logs">' + (logs.length ? logs.map(r => '<div class="sev-' + esc(r.severity_text || "INFO") + '">+' + fmtS(r.time_ns / 1e9 - t0) + ' ' +
      esc(r.severity_text || "INFO") + ' ' + esc(r.event_name ? r.event_name + ": " : "") + esc(r.body || "") + '</div>').join("") : "NO LOGS FOR THIS TRACE") + '</div></div></div>';
}

// --- Metrics (Prometheus-style samples) ---
const AGGS = { p50: v => quantile(v, 0.5), p90: v => quantile(v, 0.9), p95: v => quantile(v, 0.95), p99: v => quantile(v, 0.99), avg: v => v.length ? sum(v) / v.length : null,
  max: v => v.length ? Math.max(...v) : null, min: v => v.length ? Math.min(...v) : null, sum: v => v.length ? sum(v) : null, count: v => v.length || null };

function pageMetrics() {
  const m = obs.metric;
  const opt = (v, cur, label) => '<option value="' + esc(v) + '"' + (v === cur ? " selected" : "") + '>' + esc(label || v) + '</option>';
  return '<div class="toolbar"><div class="row">' +
    '<select id="m-name">' + (m.names.length ? m.names.map(x => opt(x.name, m.name, x.name + " (" + x.unit + ")")).join("") : '<option>loading...</option>') + '</select>' +
    '<select id="m-agg">' + Object.keys(AGGS).map(a => opt(a, m.agg)).join("") + '</select><span class="muted mono">BY</span>' +
    '<select id="m-by">' + [opt("", m.by, "(no grouping)")].concat(m.labelKeys ? m.labelKeys.map(k => opt(k, m.by)) : []).join("") + '</select></div>' +
    '<span class="muted mono" id="m-expr"></span></div><div id="m-body"></div>';
}

async function obsMetricLoad() {
  const m = obs.metric, from = Date.now() / 1000 - obs.range * 86400;
  if (!m.names.length) {
    m.names = obsRows(await obsQuery("SELECT name, unit, count(*) AS n FROM samples GROUP BY name, unit ORDER BY name"));
    if (!m.name && m.names.length) m.name = (m.names.find(x => x.name === "sayit2.release.duration") || m.names.find(x => x.name === "sayit2.finish.duration") || m.names[0]).name;
  }
  if (!m.name) return;
  m.sql = "SELECT time_ns, value, labels, trace_id FROM samples WHERE name = ?1 AND time_ns >= ?2 * 1e9 ORDER BY time_ns";
  m.rows = obsRows(await obsQuery(m.sql, [m.name, from])).map(r => ({ t: r.time_ns / 1e9, value: r.value, labels: JSON.parse(r.labels || "{}"), trace: r.trace_id }));
  m.labelKeys = [...new Set(m.rows.flatMap(r => Object.keys(r.labels)))].sort();
  m.unit = (m.names.find(x => x.name === m.name) || {}).unit;
}

function obsMetricRender() {
  const m = obs.metric, body = document.getElementById("m-body");
  if (!body) return;
  if (!m.name) { body.innerHTML = '<div class="panel muted mono">NO METRIC SAMPLES YET</div>'; return; }
  const rows = m.rows.filter(r => !r.labels["gen_ai.provider.name"] || obs.providers.has(r.labels["gen_ai.provider.name"]));
  const fmt = m.unit === "s" ? fmtS : m.unit === "1" ? fmtPct : v => Number(v).toLocaleString(undefined, { maximumFractionDigits: 2 });
  const aggFmt = m.agg === "count" ? fmtInt : fmt;
  const keyOf = r => m.by ? (r.labels[m.by] ?? "(none)") : "all";
  const groups = new Map();
  for (const r of rows) { const k = String(keyOf(r)); if (!groups.has(k)) groups.set(k, []); groups.get(k).push(r); }
  const order = Object.keys(OBS_PROVIDERS);
  const sorted = [...groups.entries()].sort((a, b) => ((order.indexOf(a[0]) + 1) || 99) - ((order.indexOf(b[0]) + 1) || 99) || a[0].localeCompare(b[0]));
  groups.clear();
  for (const [k, v] of sorted) groups.set(k, v);
  const b = timeBuckets(), palette = ["#ffde00", "#38bdf8", "#f472b6", "#a3e635", "#fb923c", "#c084fc", "#2dd4bf", "#f87171"];
  const color = (k, i) => m.by === "gen_ai.provider.name" ? opColor(k) : palette[i % palette.length];
  const series = [...groups.entries()].map(([k, list], i) => {
    const bins = b.xs.map(() => []);
    for (const r of list) { const j = b.index(r.t); if (bins[j]) bins[j].push(r.value); }
    return { label: m.by === "gen_ai.provider.name" ? opName(k) : k, color: color(k, i), values: bins.map(v => v.length ? AGGS[m.agg](v) : null) };
  });
  document.getElementById("m-expr").textContent = m.agg + "(" + m.name + ")" + (m.by ? " by (" + m.by + ")" : "") + " per " + (b.step === 3600 ? "hour" : "day");
  obs.specs = { metric: { xs: b.xs, step: b.step, series, fmt: aggFmt, height: 260 } };
  const table = [...groups.entries()].map(([k, list], i) => {
    const v = list.map(r => r.value), worst = list.reduce((a, r) => r.value > a.value ? r : a, list[0]);
    return '<tr><td class="left"><span class="dot" style="background:' + color(k, i) + '"></span>' + esc(m.by === "gen_ai.provider.name" ? opName(k) : k) + '</td><td>' + v.length + '</td><td>' + aggFmt(AGGS[m.agg](v)) + '</td>' +
      '<td>' + fmt(quantile(v, 0.5)) + '</td><td>' + fmt(quantile(v, 0.95)) + '</td><td>' + fmt(Math.max(...v)) + '</td><td><button type="button" class="btn small" data-trace="' + esc(worst.trace) + '" title="Trace of the largest sample">Exemplar</button></td></tr>';
  }).join("");
  body.innerHTML = panel(esc(m.name), '<div class="chart" id="chart-metric"></div>', { sql: m.sql.replace("?1", "'" + m.name + "'").replace("?2 * 1e9", "(unixepoch() - " + obs.range * 86400 + ") * 1e9") }) +
    panel('SERIES', '<div class="table-scroll"><table class="grid"><thead><tr><th class="left">' + esc(m.by || "series") + '</th><th>Samples</th><th>' + esc(m.agg) + '</th><th>p50</th><th>p95</th><th>max</th><th>Exemplar</th></tr></thead><tbody>' + table + '</tbody></table></div>',
      { sub: "ONE SAMPLE PER OBSERVATION, LINKED TO ITS TRACE" });
  mountCharts();
}

// --- Query (SQL) ---
const QUERY_EXAMPLES = {
  "Latency percentiles per provider": "SELECT provider, count(*) AS n,\n  round(median(release_s), 3) AS release_p50,\n  round(percentile_cont(release_s, 0.95), 3) AS release_p95,\n  round(median(first_text_s), 3) AS first_words_p50,\n  round(median(connect_s), 3) AS connect_p50\nFROM sessions WHERE outcome = 'completed'\nGROUP BY provider ORDER BY release_p50",
  "Error budget per provider": "SELECT provider, count(*) AS dictations,\n  sum(outcome = 'failed') AS failed,\n  round(100.0 * sum(outcome = 'completed') / count(*), 2) AS success_pct,\n  sum(attempts > 1) AS retried\nFROM sessions WHERE outcome != 'cancelled'\nGROUP BY provider",
  "Connection errors by code": "SELECT provider, error_type, http_status, ws_close_code, count(*) AS n, max(trace_id) AS trace_id\nFROM streams WHERE error_type IS NOT NULL\nGROUP BY 1, 2, 3, 4 ORDER BY n DESC",
  "Slowest dictations": "SELECT trace_id, provider, model, round(release_s, 3) AS release_s, round(duration_s, 2) AS total_s, attempts, outcome\nFROM sessions ORDER BY release_s DESC LIMIT 20",
  "Metric series (Prometheus style)": "SELECT name, unit, labels, samples, datetime(last_ns / 1e9, 'unixepoch', 'localtime') AS last\nFROM series ORDER BY name, samples DESC",
  "p95 of a metric by day and provider": "SELECT date(time_ns / 1e9, 'unixepoch', 'localtime') AS day,\n  labels ->> '$.\"gen_ai.provider.name\"' AS provider,\n  count(*) AS n, round(percentile_cont(value, 0.95), 3) AS p95\nFROM samples WHERE name = 'sayit2.finish.duration'\nGROUP BY day, provider ORDER BY day DESC, provider",
  "Warnings and errors": "SELECT datetime(time_ns / 1e9, 'unixepoch', 'localtime') AS time, severity_text, body, trace_id\nFROM logs WHERE severity_number >= 13\nORDER BY time_ns DESC LIMIT 100",
  "One trace end to end": "SELECT name, round((start_ns - (SELECT min(start_ns) FROM spans s2 WHERE s2.trace_id = spans.trace_id)) / 1e9, 3) AS start_s,\n  round((end_ns - start_ns) / 1e9, 3) AS duration_s, status_code, attributes\nFROM spans WHERE trace_id = (SELECT trace_id FROM sessions ORDER BY start_ns DESC LIMIT 1)\nORDER BY start_ns",
  "Schema": "SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
};
function pageQuery() {
  return '<div class="panel"><div class="panel-head"><h2>SQL <span class="accent">QUERY</span></h2><div class="row">' +
    '<select id="q-example"><option value="">Examples...</option>' + Object.keys(QUERY_EXAMPLES).map(k => '<option>' + esc(k) + '</option>').join("") + '</select>' +
    '<button type="button" class="btn primary" id="q-run">Run (Cmd+Enter)</button></div></div>' +
    '<textarea id="q-sql" spellcheck="false">' + esc(obs.querySql || QUERY_EXAMPLES["Latency percentiles per provider"]) + '</textarea>' +
    '<div class="muted small">Read-only SQLite over <code>~/.local/share/sayit2/telemetry.sqlite</code>. Tables: <code>spans</code>, <code>span_events</code>, <code>logs</code>, ' +
    '<code>samples</code> (metrics: name, labels, value, exemplar trace). Views: <code>sessions</code>, <code>streams</code>, <code>series</code>. ' +
    'Functions include <code>median</code>, <code>percentile_cont</code>, and JSON <code>-&gt;&gt;</code>. Times are nanoseconds since 1970.</div>' +
    '<div id="q-out"></div></div>';
}
async function obsRunQuery() {
  const sqlText = document.getElementById("q-sql").value, out = document.getElementById("q-out");
  obs.querySql = sqlText;
  const started = performance.now();
  out.innerHTML = '<div class="muted mono">RUNNING...</div>';
  try {
    const res = await obsQuery(sqlText);
    const ms = Math.round(performance.now() - started), cols = res.columns, shown = res.rows.slice(0, 1000);
    const cell = (c, v) => v == null ? '<td class="muted">NULL</td>' : /trace_id/.test(c) && /^[0-9a-f]{32}$/.test(v) ? '<td class="left"><button type="button" class="btn small" data-trace="' + esc(v) + '">' + esc(v.slice(0, 8)) + '</button></td>' :
      '<td class="left wrap">' + esc(typeof v === "number" && !Number.isInteger(v) ? Number(v.toPrecision(6)) : v) + '</td>';
    out.innerHTML = '<div class="muted mono small q-meta">' + res.rows.length + ' ROWS' + (res.truncated ? ' (TRUNCATED)' : '') + ', ' + ms + ' MS' + (res.rows.length > shown.length ? ', FIRST 1000 SHOWN' : '') + '</div>' +
      (cols.length ? '<div class="table-scroll"><table class="grid q-table"><thead><tr>' + cols.map(c => '<th class="left">' + esc(c) + '</th>').join("") + '</tr></thead><tbody>' +
        shown.map(r => '<tr>' + r.map((v, i) => cell(cols[i], v)).join("") + '</tr>').join("") + '</tbody></table></div>' : '');
  } catch (e) {
    out.innerHTML = '<div class="bad mono">' + esc(e.message) + '</div>';
  }
}

// --- Navigation, polling, and events ---
function obsSetPage(page) {
  obs.page = page;
  document.querySelectorAll("#obs-pages button").forEach(b => b.classList.toggle("active", b.dataset.page === page));
  if (page === "metrics") obsMetricLoad().then(renderObsPage).catch(obsShowError);
  renderObsPage();
}
function obsShowError(e) { document.getElementById("obs-subtitle").textContent = "COULD NOT READ TELEMETRY: " + e.message; }
async function obsPoll(force) {
  if (document.hidden || activeTab !== "observe") return;
  try {
    const changed = await obsLoad(force);
    if (!changed && !force) return;
    if (obs.page === "metrics") await obsMetricLoad();
    if (obs.page !== "query") renderObsPage();
  } catch (e) { obsShowError(e); }
}
function obsActivate() { obsPoll(true); }

function obsWire() {
  document.getElementById("obs-pages").onclick = e => { const b = e.target.closest("button[data-page]"); if (b) obsSetPage(b.dataset.page); };
  document.getElementById("obs-range").onclick = e => {
    const b = e.target.closest("button[data-range]");
    if (!b) return;
    obs.range = Number(b.dataset.range);
    document.querySelectorAll("#obs-range button").forEach(x => x.classList.toggle("active", x === b));
    obsPoll(true);
  };
  const dims = document.getElementById("obs-dim");
  dims.innerHTML = Object.entries(DIMS).map(([k, d]) => '<button type="button" data-dim="' + k + '"' + (k === obs.dim ? ' class="active"' : '') + '>' + esc(d.label) + '</button>').join("");
  dims.onclick = e => {
    const b = e.target.closest("button[data-dim]");
    if (!b) return;
    obs.dim = b.dataset.dim;
    if (obs.matrix.col === obs.dim) obs.matrix.col = obs.dim === "provider" ? "noise" : "provider";
    dims.querySelectorAll("button").forEach(x => x.classList.toggle("active", x === b));
    renderObsPage();
  };
  const chips = document.getElementById("obs-providers");
  chips.innerHTML = Object.entries(OBS_PROVIDERS).map(([k, v]) => '<button type="button" class="active" data-provider="' + k + '">' + opDot(k) + esc(v.name) + '</button>').join("");
  chips.onclick = e => {
    const b = e.target.closest("button[data-provider]");
    if (!b) return;
    const p = b.dataset.provider;
    if (e.altKey) obs.providers = new Set([p]);   // Option-click shows one provider alone
    else if (obs.providers.has(p) && obs.providers.size > 1) obs.providers.delete(p);
    else obs.providers.add(p);
    chips.querySelectorAll("button").forEach(x => x.classList.toggle("active", obs.providers.has(x.dataset.provider)));
    renderObsPage();
  };
  const view = document.getElementById("view-observe");
  view.addEventListener("click", e => {
    const t = e.target;
    const explore = t.closest("[data-explore]");
    if (explore) { obs.querySql = explore.dataset.explore; obsSetPage("query"); document.getElementById("q-sql").value = obs.querySql; obsRunQuery(); return; }
    const trace = t.closest("[data-trace]");
    if (trace && trace.dataset.trace) {
      obs.traceSpan = null;
      if (obs.page !== "traces") { obs.trace = trace.dataset.trace; obsSetPage("traces"); }
      else obsOpenTrace(trace.dataset.trace);
      return;
    }
    if (t.closest("[data-close-trace]")) { obs.trace = null; document.getElementById("trace-detail").innerHTML = ""; document.querySelectorAll("tr[data-trace]").forEach(r => r.classList.remove("sel")); return; }
    const span = t.closest(".wf-row[data-span]");
    if (span) { obs.traceSpan = span.dataset.span; obsOpenTrace(obs.trace, false); return; }
    const stage = t.closest("[data-stage]");
    if (stage) { obs.latencyStage = stage.dataset.stage; renderObsPage(); return; }
    const pct = t.closest("[data-pct]");
    if (pct) { obs.latencyPct = Number(pct.dataset.pct); renderObsPage(); return; }
    const outcome = t.closest("[data-outcome]");
    if (outcome) { obs.traceFilter.outcome = outcome.dataset.outcome; renderObsPage(); return; }
    if (t.id === "q-run") obsRunQuery();
  });
  view.addEventListener("change", e => {
    const t = e.target;
    if (t.id === "q-example" && t.value) { document.getElementById("q-sql").value = QUERY_EXAMPLES[t.value]; obsRunQuery(); }
    if (t.id === "m-name") { obs.metric.name = t.value; obsMetricLoad().then(renderObsPage).catch(obsShowError); }
    if (t.id === "m-agg") { obs.metric.agg = t.value; obsMetricRender(); }
    if (t.id === "m-by") { obs.metric.by = t.value; obsMetricRender(); }
    if (t.dataset.matrix) { obs.matrix[t.dataset.matrix] = t.value; renderObsPage(); }
    if (t.id === "tr-min") { obs.traceFilter.minSeconds = Number(t.value) || 0; renderObsPage(); }
  });
  view.addEventListener("input", e => {
    if (e.target.id === "tr-text") {
      obs.traceFilter.text = e.target.value;
      clearTimeout(obs.textTimer);
      obs.textTimer = setTimeout(() => { renderObsPage(); const el = document.getElementById("tr-text"); el.focus(); el.setSelectionRange(el.value.length, el.value.length); }, 250);
    }
  });
  view.addEventListener("keydown", e => {
    if (e.target.id === "q-sql" && (e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); obsRunQuery(); }
  });
  let resizeTimer = null;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { if (activeTab === "observe" && Object.keys(obs.specs).length) mountCharts(); }, 200);
  });
}
