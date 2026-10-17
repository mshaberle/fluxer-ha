#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The game-day measurement probe. See docs/testing.md.
// Run it from a machine OUTSIDE both sites, such as your laptop or the
// witness. It writes JSON lines to $OUT for analyze.mjs.
// Node >= 22 (global fetch, WebSocket, FormData). No dependencies.
//
// It probes what users experience:
//   http   GET <url>/api/_health every HTTP_EVERY_MS (MiddlewarePipeline.ts:79)
//   site   GET /_health on EACH site IP directly (SNI = domain). Detects both sites serving.
//   write  POST /api/v1/channels/:id/messages every WRITE_EVERY_MS (MessageController.ts:160)
//   upload the same, multipart with a small file, every UPLOAD_EVERY_MS (0 = off)
//   ws     gateway session: HELLO -> IDENTIFY -> READY, records MESSAGE_CREATE
//          for this run's messages, and reconnects after 1 s on close
//          (gateway_handler.erl:64-65, GatewayConstants.ts:5-18)
//
// Required env:
//   FLUXER_URL         e.g. https://chat.example.com
//   PROBE_TOKEN        HTTP Authorization value, e.g. "Bot <token>" (UserMiddleware.ts:43-49)
//   PROBE_CHANNEL_ID   a channel in a TEST guild that only the probe bots use
// Optional env:
//   PROBE_GATEWAY_TOKEN   token for IDENTIFY. Defaults to PROBE_TOKEN without the "Bot "
//                         prefix. The API strips a "Bot " prefix itself before it
//                         checks an IDENTIFY token, so either form works
//                         (RpcService.ts normalizeSessionToken, parseTokenType).
//   SITE_IPS              comma-separated public IPs of site1,site2 (for the "site" probe)
//   OUT                   output file (default ./probe-<run>.jsonl)
//   HTTP_EVERY_MS=1000 WRITE_EVERY_MS=2000 UPLOAD_EVERY_MS=0 TIMEOUT_MS=5000
//   WRITER_ID             label when several probes or load writers share one analysis
//   HEARTBEAT_MAX_MS=10000  heartbeat at most this far apart; two unacknowledged = dead connection

import {appendFileSync} from 'node:fs';
import https from 'node:https';
import {createHash, randomBytes} from 'node:crypto';

const env = (k, d) => process.env[k] ?? d;
const URL_BASE = env('FLUXER_URL');
const TOKEN = env('PROBE_TOKEN');
const CHANNEL = env('PROBE_CHANNEL_ID');
if (!URL_BASE || !TOKEN || !CHANNEL) {
	console.error('set FLUXER_URL, PROBE_TOKEN, PROBE_CHANNEL_ID');
	process.exit(2);
}
const GW_TOKEN = env('PROBE_GATEWAY_TOKEN', TOKEN.replace(/^Bot /, ''));
const RUN = env('RUN_ID', new Date().toISOString().replace(/[:.]/g, '-'));
const WRITER = env('WRITER_ID', 'probe');
const OUT = env('OUT', `./probe-${RUN}.jsonl`);
const NONCE_BASE = createHash('sha256').update(`${RUN}/${WRITER}`).digest('hex').slice(0, 16);
const HTTP_EVERY = Number(env('HTTP_EVERY_MS', 1000));
const WRITE_EVERY = Number(env('WRITE_EVERY_MS', 2000));
const UPLOAD_EVERY = Number(env('UPLOAD_EVERY_MS', 0));
const TIMEOUT = Number(env('TIMEOUT_MS', 5000));
const SITE_IPS = env('SITE_IPS', '').split(',').filter(Boolean);
const host = new URL(URL_BASE).hostname;

const log = (kind, data) => appendFileSync(OUT, `${JSON.stringify({t: Date.now(), run: RUN, writer: WRITER, kind, ...data})}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let stopping = false;
process.on('SIGINT', () => { stopping = true; console.error(`\nstopping; log in ${OUT}`); setTimeout(() => process.exit(0), 1500); });

async function timed(fn) {
	const started = Date.now();
	try { return {...(await fn()), ms: Date.now() - started}; }
	catch (e) { return {ok: false, err: String(e?.cause?.code ?? e?.name ?? e), ms: Date.now() - started}; }
}

async function httpLoop() {
	while (!stopping) {
		const r = await timed(async () => {
			const res = await fetch(`${URL_BASE}/api/_health`, {signal: AbortSignal.timeout(TIMEOUT)});
			return {ok: res.ok, status: res.status};
		});
		log('http', r);
		await sleep(HTTP_EVERY);
	}
}

// Probe one site by IP while presenting the real hostname (TLS SNI + Host).
function siteHealth(ip) {
	return new Promise((resolve) => {
		const req = https.request({host: ip, servername: host, path: '/_health', headers: {host}, timeout: TIMEOUT}, (res) => {
			res.resume(); resolve({ok: res.statusCode === 200, status: res.statusCode});
		});
		req.on('timeout', () => { req.destroy(); resolve({ok: false, err: 'timeout'}); });
		req.on('error', (e) => resolve({ok: false, err: e.code ?? String(e)}));
		req.end();
	});
}
async function siteLoop() {
	if (SITE_IPS.length === 0) return;
	while (!stopping) {
		for (const ip of SITE_IPS) log('site', {ip, ...(await siteHealth(ip))});
		await sleep(HTTP_EVERY);
	}
}

let seq = 0;
// Fluxer refuses a user's first message until that user has a gateway session
// (MUST_START_SESSION_BEFORE_SENDING), so writes and uploads wait for the
// first READY; after that, an outage counts as an outage.
let firstReady; const sessionStarted = new Promise((r) => { firstReady = r; });
async function writeLoop() {
	await sessionStarted;
	while (!stopping) {
		const n = ++seq;
		// The API takes a nonce of at most 32 characters (MessageNonceRequest);
		// longer ones are refused with 400. A short hash of run and writer keeps it unique.
		const nonce = `${NONCE_BASE}-${n}`;
		const r = await timed(async () => {
			const res = await fetch(`${URL_BASE}/api/v1/channels/${CHANNEL}/messages`, {
				method: 'POST',
				headers: {Authorization: TOKEN, 'Content-Type': 'application/json'},
				body: JSON.stringify({content: `hagd run=${RUN} writer=${WRITER} seq=${n}`, nonce}),
				signal: AbortSignal.timeout(TIMEOUT),
			});
			const body = await res.json().catch(() => ({}));
			return {ok: res.ok, status: res.status, id: body?.id ?? null};
		});
		log('write', {seq: n, nonce, ...r});
		await sleep(WRITE_EVERY);
	}
}

let up = 0;
async function uploadLoop() {
	if (UPLOAD_EVERY <= 0) return;
	await sessionStarted;
	while (!stopping) {
		const n = ++up;
		const r = await timed(async () => {
			const fd = new FormData();
			// `payload_json` + `files[0]`: the names MessageRequestParser.ts accepts
			// (FIELD_NAME_PATTERN /^files\[(\d+)\]$/); analyze.mjs --verify read them back in the lab.
			// Two files, a text and a binary one, each with its sha256 logged, so
			// analyze.mjs --verify can check the bytes served back, not only that
			// a URL answers.
			const files = [
				{name: `hagd-${n}.txt`, type: 'text/plain', data: Buffer.from(`hagd ${RUN} ${n} ${Date.now()}\n`)},
				{name: `hagd-${n}.bin`, type: 'application/octet-stream', data: randomBytes(4096 + (n % 7) * 512)},
			].map((x) => ({...x, size: x.data.length, sha256: createHash('sha256').update(x.data).digest('hex')}));
			fd.set('payload_json', JSON.stringify({content: `hagd-upload run=${RUN} writer=${WRITER} up=${n}`}));
			files.forEach((x, i) => fd.set(`files[${i}]`, new Blob([x.data], {type: x.type}), x.name));
			const res = await fetch(`${URL_BASE}/api/v1/channels/${CHANNEL}/messages`, {
				method: 'POST', headers: {Authorization: TOKEN}, body: fd, signal: AbortSignal.timeout(TIMEOUT * 4),
			});
			const body = await res.json().catch(() => ({}));
			const att = (body?.attachments ?? []).map((a) => ({name: a.filename, url: a.url ?? a.proxy_url ?? null, size: a.size}));
			const sent = files.map(({name, size, sha256}) => ({name, size, sha256, url: att.find((a) => a.name === name)?.url ?? null}));
			return {ok: res.ok && sent.every((x) => x.url), status: res.status, id: body?.id ?? null, url: sent[0]?.url ?? null, files: sent};
		});
		log('upload', {up: n, ...r});
		await sleep(UPLOAD_EVERY);
	}
}

async function wsLoop() {
	while (!stopping) {
		const opened = Date.now();
		await new Promise((resolve) => {
			let hb = null;
			let lastSeq = null;
			const gw = `${URL_BASE.replace(/^http/, 'ws')}/gateway?v=1&encoding=json`;
			let ws;
			try { ws = new WebSocket(gw); } catch (e) { log('ws', {ev: 'error', err: String(e)}); return resolve(); }
			let finished = false;
			const done = (ev, extra = {}) => { if (finished) return; finished = true; clearInterval(hb); clearTimeout(readyTimer); log('ws', {ev, ...extra}); resolve(); };
			// A handshake that never completes (seen in the lab during a failover)
			// would otherwise stall gateway measurement for the rest of the run.
			const readyTimer = setTimeout(() => { try { ws.close(); } catch {} done('timeout', {after_ms: Date.now() - opened}); }, 15000);
			ws.onmessage = (m) => {
				let p; try { p = JSON.parse(m.data); } catch { return; }
				if (p.s != null) lastSeq = p.s;
				if (p.op === 10) {
					// Zombie detection, as real clients do: a heartbeat sent while the
					// previous one is still unacknowledged means the connection is dead
					// (a powered-off host never closes its sockets: lab, F17).
					let acked = true;
					hb = setInterval(() => {
						if (!acked) { try { ws.close(); } catch {} done('zombie'); return; }
						acked = false;
						try { ws.send(JSON.stringify({op: 1, d: lastSeq})); } catch {}
					}, Math.min(p.d?.heartbeat_interval ?? 41250, Number(env('HEARTBEAT_MAX_MS', 10000))));
					ws.addEventListener('message', (m2) => { try { if (JSON.parse(m2.data).op === 11) acked = true; } catch {} });
					ws.send(JSON.stringify({op: 2, d: {token: GW_TOKEN, properties: {os: 'linux', browser: 'fluxer-ha-probe', device: 'fluxer-ha-probe'}}}));
				} else if (p.op === 0 && p.t === 'READY') {
					clearTimeout(readyTimer);
					log('ws', {ev: 'ready', since_open_ms: Date.now() - opened});
					firstReady();
				} else if (p.op === 0 && p.t === 'MESSAGE_CREATE' && typeof p.d?.content === 'string' && p.d.content.includes(`run=${RUN} `)) {
					log('ws', {ev: 'message', id: p.d.id, content: p.d.content});
				} else if (p.op === 9) {
					log('ws', {ev: 'invalid_session'});
				}
			};
			ws.onclose = (e) => done('close', {code: e.code});
			ws.onerror = () => {};
		});
		if (!stopping) await sleep(1000);
	}
}

log('start', {url: URL_BASE, channel: CHANNEL, site_ips: SITE_IPS});
console.error(`probe run=${RUN} writing ${OUT}. Ctrl-C to stop.`);
await Promise.all([httpLoop(), siteLoop(), writeLoop(), uploadLoop(), wsLoop()]);
