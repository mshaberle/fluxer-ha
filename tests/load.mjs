#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Background load for a "fail over under load" drill. See docs/testing.md.
// Node >= 22, no dependencies.
//
// Each line of TOKENS_FILE is one HTTP Authorization value ("Bot <token>"), one
// test bot each, so per-user rate limits (RateLimitService.ts) don't cap the
// load. Each bot writes to PROBE_CHANNEL_ID every WRITE_EVERY_MS. The JSON-lines
// output has the same schema as probe.mjs (kind=write), so analyze.mjs
// --verify checks every acknowledged load message for loss too.
//
// The default load is ~10 writers x 1 msg/s, about 10x the expected peak
// (00-context.md: ~10 users, messages per hour).
//
// Env: FLUXER_URL, PROBE_CHANNEL_ID, TOKENS_FILE, WRITE_EVERY_MS=1000, OUT, RUN_ID, TIMEOUT_MS=5000

import {createHash} from 'node:crypto';
import {appendFileSync, readFileSync} from 'node:fs';

const env = (k, d) => process.env[k] ?? d;
const URL_BASE = env('FLUXER_URL');
const CHANNEL = env('PROBE_CHANNEL_ID');
const tokens = readFileSync(env('TOKENS_FILE', './tokens.txt'), 'utf8').split('\n').map((l) => l.trim()).filter(Boolean);
if (!URL_BASE || !CHANNEL || tokens.length === 0) { console.error('set FLUXER_URL, PROBE_CHANNEL_ID, TOKENS_FILE'); process.exit(2); }
const RUN = env('RUN_ID', new Date().toISOString().replace(/[:.]/g, '-'));
const OUT = env('OUT', `./load-${RUN}.jsonl`);
const EVERY = Number(env('WRITE_EVERY_MS', 1000));
const TIMEOUT = Number(env('TIMEOUT_MS', 5000));
let stopping = false;
process.on('SIGINT', () => { stopping = true; setTimeout(() => process.exit(0), 1500); });

const log = (writer, data) => appendFileSync(OUT, `${JSON.stringify({t: Date.now(), run: RUN, writer, kind: 'write', ...data})}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function writer(token, idx) {
	const name = `load${idx}`;
	await sleep(Math.floor(Math.random() * EVERY)); // spread the writers out
	for (let seq = 1; !stopping; seq++) {
		const started = Date.now();
		try {
			const res = await fetch(`${URL_BASE}/api/v1/channels/${CHANNEL}/messages`, {
				method: 'POST',
				headers: {Authorization: token, 'Content-Type': 'application/json'},
				body: JSON.stringify({content: `hagd run=${RUN} writer=${name} seq=${seq}`, nonce: `${createHash('sha256').update(`${RUN}/${name}`).digest('hex').slice(0, 16)}-${seq}`}),
				signal: AbortSignal.timeout(TIMEOUT),
			});
			const body = await res.json().catch(() => ({}));
			log(name, {seq, ok: res.ok, status: res.status, id: body?.id ?? null, ms: Date.now() - started});
		} catch (e) {
			log(name, {seq, ok: false, err: String(e?.cause?.code ?? e?.name ?? e), ms: Date.now() - started});
		}
		await sleep(Math.max(0, EVERY - (Date.now() - started)));
	}
}

console.error(`load run=${RUN}: ${tokens.length} writers every ${EVERY}ms -> ${OUT}`);
await Promise.all(tokens.map(writer));
