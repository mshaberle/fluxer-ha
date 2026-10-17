#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Computes measured RTO and RPO from probe/load logs, then checks the
// pass/fail criteria. See docs/testing.md.
// Node >= 22, no dependencies.
//
//   node analyze.mjs --inject 2026-10-09T14:03:12Z [--verify] [--profile unplanned] probe-*.jsonl load-*.jsonl
//
// --inject   when the fault was injected (printed by the gd-*.sh scripts as INJECT_AT=...)
// --verify   also read the channel back through the API (needs FLUXER_URL, PROBE_TOKEN,
//            PROBE_CHANNEL_ID) to find acknowledged-but-missing messages (RPO), duplicates,
//            out-of-order IDs and unavailable attachments
// --profile  which pass/fail thresholds to apply (see PROFILES)
// --max-http / --max-write / --max-ws / --max-split <seconds>   override one threshold

import {readFileSync} from 'node:fs';

const PROFILES = {
	// Thresholds in seconds. null = not checked for this profile.
	'no-impact':  {http: 0,   write: 10,  ws: 30,  split: 0},   // e.g. witness down, replica down
	'service':    {http: 120, write: 120, ws: 150, split: 0},   // single service killed on the primary
	'planned':    {http: 120, write: 120, ws: 180, split: 10},  // patronictl switchover
	'unplanned':  {http: 150, write: 180, ws: 240, split: 10},  // node loss, partition, under load
};

const args = process.argv.slice(2);
const opt = (name, d = null) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : d; };
const flag = (name) => args.includes(`--${name}`);
const files = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--') && !['--verify'].includes(args[i - 1])));
const injectIso = opt('inject');
if (!injectIso || files.length === 0) { console.error('usage: analyze.mjs --inject <ISO> [--verify] [--profile p] <jsonl...>'); process.exit(2); }
const T0 = Date.parse(injectIso);
const base = PROFILES[opt('profile', 'unplanned')];
if (!base) { console.error(`unknown profile; one of ${Object.keys(PROFILES).join(', ')}`); process.exit(2); }
// Per-run overrides in seconds, e.g. --max-write 30 for GD-3b/4a/5c.
const profile = {...base};
for (const k of ['http', 'write', 'ws', 'split']) { const v = opt(`max-${k}`); if (v != null) profile[k] = Number(v); }

const ev = files.flatMap((f) => readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))).sort((a, b) => a.t - b.t);
const s = (ms) => (ms == null ? 'n/a' : `${(ms / 1000).toFixed(1)}s`);
const results = [];
const check = (name, ok, detail) => results.push({name, ok, detail});

// RTO for a stream of {t, ok}: the time from T0 to the first success that starts
// a run of `stable` successes, counted only if a failure happened after T0 - 5 s.
function rto(stream, stable) {
	const after = stream.filter((e) => e.t >= T0 - 5000);
	const firstFail = after.find((e) => !e.ok);
	if (!firstFail) return {impact: false, rto: 0, firstFail: null};
	for (let i = after.indexOf(firstFail); i < after.length; i++) {
		if (after.slice(i, i + stable).length === stable && after.slice(i, i + stable).every((e) => e.ok)) {
			return {impact: true, rto: Math.max(0, after[i].t - T0), firstFail: firstFail.t - T0};
		}
	}
	return {impact: true, rto: null, firstFail: firstFail.t - T0};
}

const http = rto(ev.filter((e) => e.kind === 'http'), 10);
const write = rto(ev.filter((e) => e.kind === 'write'), 3);
// Gateway: the first close at/after T0, then the first READY after it.
const wsEv = ev.filter((e) => e.kind === 'ws' && e.t >= T0 - 5000);
// zombie (unacknowledged heartbeats) and timeout (no READY) are disconnects too (probe.mjs, lab F17).
const wsClose = wsEv.find((e) => ['close', 'error', 'zombie', 'timeout'].includes(e.ev));
const wsReady = wsClose ? wsEv.find((e) => e.ev === 'ready' && e.t > wsClose.t) : null;
const wsRto = wsClose ? (wsReady ? wsReady.t - T0 : null) : 0;

console.log(`inject ${new Date(T0).toISOString()}, profile ${opt('profile', 'unplanned')}`);
console.log(`HTTP  : impact=${http.impact} first-fail=${s(http.firstFail)} RTO=${s(http.rto)}`);
console.log(`WRITE : impact=${write.impact} first-fail=${s(write.firstFail)} RTO=${s(write.rto)}`);
console.log(`WS    : ${wsClose ? `closed at ${s(wsClose.t - T0)}, READY again ${s(wsRto)}` : 'no disconnect'}`);
const lim = (k, v) => profile[k] == null || (v != null && v <= profile[k] * 1000);
check('http RTO', lim('http', http.rto), `${s(http.rto)} <= ${profile.http}s`);
check('write RTO', lim('write', write.rto), `${s(write.rto)} <= ${profile.write}s`);
check('gateway RTO', lim('ws', wsRto), `${s(wsRto)} <= ${profile.ws}s`);

// Both sites serving at once. Per 1 s bucket, how many site IPs answered 200?
const site = ev.filter((e) => e.kind === 'site');
if (site.length) {
	const buckets = new Map();
	for (const e of site) { if (!e.ok) continue; const b = Math.floor(e.t / 1000); (buckets.get(b) ?? buckets.set(b, new Set()).get(b)).add(e.ip); }
	let both = 0, run = 0, maxRun = 0;
	for (const [, ips] of [...buckets].sort((a, b) => a[0] - b[0])) { if (ips.size > 1) { both++; run++; maxRun = Math.max(maxRun, run); } else run = 0; }
	console.log(`SITES : seconds with BOTH sites answering = ${both}, longest stretch = ${maxRun}s`);
	check('no dual serving', maxRun <= profile.split, `${maxRun}s <= ${profile.split}s`);
}

// RPO and ordering. Needs the API (--verify).
const acked = ev.filter((e) => e.kind === 'write' && e.ok && e.id);
const failedSeqs = new Set(ev.filter((e) => e.kind === 'write' && !e.ok).map((e) => `${e.writer}:${e.seq}`));
const uploads = ev.filter((e) => e.kind === 'upload' && e.ok && e.url);
console.log(`acked writes=${acked.length}, failed writes=${failedSeqs.size}, acked uploads=${uploads.length}`);

// Per writer, IDs must increase with seq: the clock gate and per-channel monotonicity.
const byWriter = Map.groupBy(acked, (e) => e.writer);
let nonMono = 0;
for (const [, list] of byWriter) { list.sort((a, b) => a.seq - b.seq); for (let i = 1; i < list.length; i++) if (BigInt(list[i].id) <= BigInt(list[i - 1].id)) nonMono++; }
check('IDs monotonic per writer', nonMono === 0, `${nonMono} inversions`);
const ids = acked.map((e) => e.id);
check('no duplicate acked IDs', new Set(ids).size === ids.length, `${ids.length - new Set(ids).size} duplicates`);

if (flag('verify')) {
	const {FLUXER_URL, PROBE_TOKEN, PROBE_CHANNEL_ID} = process.env;
	if (!FLUXER_URL || !PROBE_TOKEN || !PROBE_CHANNEL_ID) { console.error('--verify needs FLUXER_URL, PROBE_TOKEN, PROBE_CHANNEL_ID'); process.exit(2); }
	const runs = new Set(ev.map((e) => e.run));
	// Page forward with `after` (MessagesQuery: MessageRequestSchemas.ts:390-396) from just before the oldest acked ID.
	const minId = ids.reduce((m, x) => (BigInt(x) < m ? BigInt(x) : m), BigInt(ids[0] ?? '1'));
	let cursor = (minId - 1n).toString();
	const seen = new Map();
	for (let page = 0; page < 1000; page++) {
		// Retry: right after a failover, DNS can still hand out the old site, whose
		// edge closes the connection (lab). Give it up to about a minute.
		let res = null;
		for (let attempt = 0; attempt < 30 && !res?.ok; attempt++) {
			if (attempt) await new Promise((r) => setTimeout(r, 2000));
			res = await fetch(`${FLUXER_URL}/api/v1/channels/${PROBE_CHANNEL_ID}/messages?limit=100&after=${cursor}`, {headers: {Authorization: PROBE_TOKEN}}).catch(() => null);
		}
		if (!res) { console.error('history fetch failed: no connection after retries'); process.exit(1); }
		if (!res.ok) { console.error(`history fetch failed: ${res.status}`); process.exit(1); }
		const msgs = await res.json();
		if (!Array.isArray(msgs) || msgs.length === 0) break;
		for (const m of msgs) seen.set(m.id, m);
		const max = msgs.reduce((mx, m) => (BigInt(m.id) > mx ? BigInt(m.id) : mx), 0n);
		if (max.toString() === cursor) break;
		cursor = max.toString();
		await new Promise((r) => setTimeout(r, 250));
	}
	const missing = acked.filter((e) => !seen.has(e.id));
	console.log(`history: ${seen.size} messages read back`);
	if (missing.length) {
		const first = Math.min(...missing.map((e) => e.t)), last = Math.max(...missing.map((e) => e.t));
		console.log(`MISSING acked messages: ${missing.length}, acked between ${s(first - T0)} and ${s(last - T0)} relative to inject`);
	}
	check('RPO: no acknowledged message lost', missing.length === 0, `${missing.length} missing`);
	// "Ghosts" are committed but never acknowledged to the client (it timed out). Informational only.
	let ghosts = 0;
	for (const m of seen.values()) {
		const mm = /run=(\S+) writer=(\S+) seq=(\d+)/.exec(m.content ?? '');
		if (mm && runs.has(mm[1]) && failedSeqs.has(`${mm[2]}:${mm[3]}`)) ghosts++;
	}
	console.log(`ghost writes (stored, but the client saw a failure): ${ghosts}. Informational.`);
	// Every acknowledged attachment: still served, and byte for byte what was
	// sent (sha256 and size from probe.mjs; older logs have only the URL).
	const {createHash} = await import('node:crypto');
	let lost = 0, wrong = 0, checked = 0;
	for (const u of uploads) {
		for (const f of u.files ?? [{url: u.url}]) {
			if (!f.url) { lost++; continue; }
			// The same retry as the history (DNS can still hand out the old site
			// right after a failover), but only for no answer or a 5xx: a 404 is final.
			let r = null;
			for (let attempt = 0; attempt < 30; attempt++) {
				if (attempt) await new Promise((r2) => setTimeout(r2, 2000));
				r = await fetch(f.url, {method: 'GET'}).catch(() => null);
				if (r && r.status < 500) break;
			}
			if (!r || !r.ok) { lost++; console.log(`UNAVAILABLE: ${f.name ?? f.url} (${r ? `HTTP ${r.status}` : 'no connection'} after retries)`); continue; }
			const buf = Buffer.from(await r.arrayBuffer());
			if (f.sha256) {
				checked++;
				if (buf.length !== f.size || createHash('sha256').update(buf).digest('hex') !== f.sha256) { wrong++; console.log(`WRONG CONTENT: ${f.name} (${buf.length} bytes, expected ${f.size})`); }
			}
			await new Promise((r2) => setTimeout(r2, 50));
		}
	}
	check('media: acked attachments retrievable', lost === 0, `${lost} unavailable${lost ? '. Re-run after the old primary rejoins (stranded-media recovery).' : ''}`);
	check('media: attachments have the bytes that were sent', wrong === 0, `${checked} compared by sha256, ${wrong} differ`);
}

console.log('\nRESULT');
for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name.padEnd(36)} ${r.detail}`);
process.exit(results.every((r) => r.ok) ? 0 : 1);
