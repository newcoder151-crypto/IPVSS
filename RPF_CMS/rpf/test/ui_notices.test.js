/**
 * Browser-level test of the pop-up notices and tab counters: the real dashboard page (public/app.js) runs in jsdom against the
 * real RPF server and database. Skipped unless RPF_TEST=1, JWT_SECRET and the `jsdom` package (npm i -D jsdom) are present.
 * DEV DATABASES ONLY (it inserts rows, like workflow.test.js).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

let JSDOM = null; try { ({ JSDOM } = require('jsdom')); } catch (_) { /* optional */ }
const enabled = process.env.RPF_TEST === '1' && process.env.JWT_SECRET && JSDOM;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rpf-ui-'));
process.env.MEDIA_ROOT = tmp; process.env.POST_FILE = path.join(tmp, 'post.json');

test('pop-up notices and tab counters, page + server + database', { skip: !enabled && 'needs RPF_TEST=1, JWT_SECRET and jsdom' }, async (t) => {
  const { Pool } = require('pg'); const bcrypt = require('bcryptjs');
  const { buildApp } = require('../src/server'); const { pool: appPool } = require('../src/db');
  const owner = new Pool({ host: process.env.DB_HOST || 'localhost', port: Number(process.env.DB_PORT) || 5432, database: process.env.DB_NAME || 'cms',
    user: process.env.TEST_OWNER_USER || process.env.DB_USER, password: process.env.TEST_OWNER_PASSWORD || process.env.DB_PASSWORD });
  const q = async (s, p) => (await owner.query(s, p)).rows;
  const sfx = Date.now().toString(36); const pw = 'pw-' + sfx;
  const [zone] = await q(`INSERT INTO zone (name) VALUES ($1) RETURNING id`, [`U-zone-${sfx}`]);
  const [post] = await q(`INSERT INTO rpf_post (zone_id, name, location) VALUES ($1, $2, ST_SetSRID(ST_MakePoint(80.1, 26), 4326)::geography) RETURNING id`, [zone.id, `U-post-${sfx}`]);
  const [other] = await q(`INSERT INTO rpf_post (zone_id, name, location) VALUES ($1, $2, ST_SetSRID(ST_MakePoint(81.5, 26), 4326)::geography) RETURNING id`, [zone.id, `U-other-${sfx}`]);
  await q(`INSERT INTO users (zone_id, post_id, role, username, password_hash) VALUES ($1, $2, 'post_user', $3, $4)`, [zone.id, post.id, `u-${sfx}`, await bcrypt.hash(pw, 4)]);
  const [op] = await q(`INSERT INTO users (zone_id, role, username, password_hash) VALUES ($1, 'operator', $2, 'x') RETURNING id`, [zone.id, `uop-${sfx}`]);
  const [nvr] = await q(`INSERT INTO nvr_unit (name, cert_fingerprint, current_zone_id) VALUES ($1, $2, $3) RETURNING id`, [`U-nvr-${sfx}`, `ufp-${sfx}`, zone.id]);
  const [cam] = await q(`INSERT INTO camera (nvr_id, name) VALUES ($1, 'cam-1') RETURNING id`, [nvr.id]);

  const server = buildApp().listen(0); const base = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => { server.close(); await appPool.end(); await owner.end(); fs.rmSync(tmp, { recursive: true, force: true }); });
  const call = async (method, url, token, body) => {
    const r = await fetch(base + url, { method, headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: r.status, body: (r.headers.get('content-type') || '').includes('json') ? await r.json() : null };
  };
  const token = (await call('POST', '/api/auth/login', null, { username: `u-${sfx}`, password: pw })).body.token;

  // ---- the page ----
  const dom = new JSDOM('<body><div id="app"></div></body>', { runScripts: 'outside-only', url: base + '/', pretendToBeVisual: true });
  const w = dom.window; w.sessionStorage.setItem('rpf_token', token);
  w.fetch = (u, o) => fetch(base + u, o); w.__theme = { get: () => 'dark', toggle() {}, set() {} };
  w.EventSource = function () { this.close = () => {}; this.addEventListener = () => {}; };   // no live stream here: the test drives the polling itself
  let tick = null; w.setInterval = (f) => { tick = f; return 1; };
  w.localStorage.setItem('rpf_sound', 'off');
  w.eval(fs.readFileSync(path.join(__dirname, '..', 'public', 'app.js'), 'utf8'));
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const doc = w.document;
  const pill = (id) => { const e = doc.getElementById(id); return e && !e.classList.contains('hidden') ? e.textContent : ''; };
  const toasts = () => [...doc.querySelectorAll('.ntoast')].map((e) => e.textContent);
  const settle = async () => { await tick(); await wait(500); };
  await wait(800); await tick(); await wait(400);   // the page has loaded and remembered its starting state

  await t.test('nothing pops up for what already existed; counters start empty', async () => {
    assert.deepEqual(toasts(), []);
    assert.equal(pill('footage-pill') + pill('flags-pill') + pill('requests-pill'), '');
  });

  // ---- CMS delivers footage for a request, the way requestService.deliver does: row + notice ----
  const t0 = new Date(Date.now() - 600000);
  const [r1] = await q(`INSERT INTO video_request (post_id, requested_by, camera_id, window_start, window_end, reason, status) VALUES ($1, $2, $3, $4, $5, 'ui test', 'approved') RETURNING id`, [post.id, op.id, cam.id, t0, new Date(t0.getTime() + 300000)]);
  await q(`INSERT INTO notification (zone_id, post_id, kind, title, body, ref_entity, ref_id) VALUES ($1, $2, 'request', $3, 'on its way', 'video_request', $4)`, [zone.id, post.id, `Request #${r1.id} approved - waiting for the train's NVR`, r1.id]);
  await settle();
  await t.test('a request step announced by CMS pops up and the open-requests counter shows it', async () => {
    assert.ok(toasts().some((x) => x.includes(`Request #${r1.id} approved`)), JSON.stringify(toasts()));
    assert.equal(pill('requests-pill'), '1');
  });

  const [f1] = await q(`INSERT INTO delivered_footage (video_request_id, storage_path, format, sha256, file_size_bytes, start_time, end_time, duration_s, segment_count) VALUES ($1, $2, 'MP4', $3, 10, $4, $5, 300, 1) RETURNING id`, [r1.id, `zone-${zone.id}/req-${r1.id}.mp4`, 'ab'.repeat(32), t0, new Date(t0.getTime() + 300000)]);
  await q(`UPDATE video_request SET status = 'fulfilled', fulfilled_at = now() WHERE id = $1`, [r1.id]);
  await q(`INSERT INTO notification (zone_id, post_id, kind, title, body, ref_entity, ref_id) VALUES ($1, $2, 'footage', $3, 'cam-1 / nvr', 'delivered_footage', $4)`, [zone.id, post.id, `Footage ready for request #${r1.id}`, f1.id]);
  await settle();
  await t.test('footage delivered: pop-up, bell and Footage counter', async () => {
    const x = toasts().find((s) => s.includes('Footage delivered'));
    assert.ok(x && x.includes(`Footage ready for request #${r1.id}`), JSON.stringify(toasts()));
    assert.equal(pill('footage-pill'), '1');
    assert.equal(pill('bell-pill'), '2');
    assert.equal(pill('requests-pill'), '', 'the request is no longer open');
  });

  // evidence: CMS archives a flagged clip
  const [officer] = await q(`SELECT id FROM users WHERE username = $1`, [`u-${sfx}`]);
  const [fl] = await q(`INSERT INTO evidence_flag (footage_id, flagged_by, retention, retain_from, justification, storage) VALUES ($1, $2, 'permanent', now(), 'ui test', 'cms') RETURNING id`, [f1.id, officer.id]);
  await q(`INSERT INTO notification (zone_id, post_id, kind, title, body, ref_entity, ref_id) VALUES ($1, $2, 'evidence', $3, NULL, 'evidence_flag', $4)`, [zone.id, post.id, `Evidence #${fl.id} archived on CMS`, fl.id]);
  await settle();
  await t.test('evidence notice: pop-up and Evidence counter; opening the tab clears it', async () => {
    assert.ok(toasts().some((x) => x.includes(`Evidence #${fl.id} archived`)), JSON.stringify(toasts()));
    assert.equal(pill('flags-pill'), '1');
    doc.querySelector('[data-tab="flags"]').click(); await wait(700);
    assert.equal(pill('flags-pill'), '');
    assert.equal(Number((await call('GET', '/api/alerts/summary', token)).body.unread_evidence), 0);
  });

  await t.test('playing the footage clears its counter and the NEW mark', async () => {
    assert.equal((await call('GET', '/api/footage', token)).body[0].is_new, true);
    assert.equal((await call('POST', `/api/footage/${f1.id}/access`, token, { purpose: 'view' })).status, 404, 'no file on disk in this test, so no link is issued');
    // the file exists -> a view is logged -> not new any more
    fs.mkdirSync(path.join(tmp, `zone-${zone.id}`), { recursive: true }); fs.writeFileSync(path.join(tmp, `zone-${zone.id}`, `req-${r1.id}.mp4`), 'x');
    assert.equal((await call('POST', `/api/footage/${f1.id}/access`, token, { purpose: 'view' })).status, 200);
    await settle();
    assert.equal((await call('GET', '/api/footage', token)).body[0].is_new, false);
    assert.equal(pill('footage-pill'), '');
  });

  await t.test('alerts and incidents: Unacknowledged/Acknowledged and Open/Closed tabs, driven through the page', async () => {
    const t1 = new Date(Date.now() - 120000);
    const [al] = await q(`INSERT INTO alert (nvr_id, nvr_event_id, camera_id, zone_id, alert_type, priority, event_time, location, status, routing_mode, assigned_post_id) VALUES ($1, $2, $3, $4, 'intrusion', 8, $5, ST_SetSRID(ST_MakePoint(80.1, 26), 4326)::geography, 'routed', 'auto', $6) RETURNING id`, [nvr.id, `ui-${sfx}`, cam.id, zone.id, t1, post.id]);
    const [dl] = await q(`INSERT INTO alert_delivery (alert_id, alert_event_time, post_id) VALUES ($1, $2, $3) RETURNING id`, [al.id, t1, post.id]);
    const [inc] = await q(`INSERT INTO incident (alert_delivery_id, post_id, alert_type, location, occurred_at, raised_by, title) VALUES ($1, $2, 'intrusion', ST_SetSRID(ST_MakePoint(80.1, 26), 4326)::geography, $3, $4, 'tab test') RETURNING id`, [dl.id, post.id, t1, op.id]);
    const tab = (label) => [...doc.querySelectorAll('.subtab')].find((b) => b.textContent.startsWith(label));
    const count = (label) => tab(label).querySelector('.pill').textContent;
    const cards = () => doc.querySelectorAll('.acard').length;
    doc.querySelector('[data-tab="alerts"]').click(); await wait(700);
    assert.equal(tab('Unacknowledged').classList.contains('on'), true, 'opens on the Unacknowledged tab');
    assert.equal(count('Unacknowledged'), '1'); assert.equal(count('Acknowledged'), '0'); assert.equal(cards(), 1);
    [...doc.querySelectorAll('.acard-act button')].find((b) => /Acknowledge/.test(b.textContent)).click(); await wait(900);
    assert.equal(count('Unacknowledged'), '0', 'acknowledged alert left the Unacknowledged tab');
    assert.equal(count('Acknowledged'), '1');
    assert.equal(cards(), 0, 'nothing left waiting');
    tab('Acknowledged').click(); await wait(700);
    assert.equal(cards(), 1, 'it is now listed under Acknowledged');
    doc.querySelector('[data-tab="incidents"]').click(); await wait(700);
    assert.equal(count('Open incidents'), '1'); assert.equal(count('Closed incidents'), '0');
    assert.equal(doc.querySelectorAll('.icard').length, 1);
    assert.equal((await call('PATCH', `/api/incidents/${inc.id}/status`, token, { status: 'closed', note: 'done' })).status, 200);
    await settle(); doc.querySelector('[data-tab="incidents"]').click(); await wait(700);
    assert.equal(count('Open incidents'), '0'); assert.equal(count('Closed incidents'), '1');
    assert.equal(doc.querySelectorAll('.icard').length, 0, 'closed incident left the Open tab');
    tab('Closed incidents').click(); await wait(700);
    assert.equal(doc.querySelectorAll('.icard').length, 1, 'it is listed under Closed incidents');
  });

  await t.test('another post\'s notices never reach this post', async () => {
    await q(`INSERT INTO notification (zone_id, post_id, kind, title, ref_entity, ref_id) VALUES ($1, $2, 'footage', 'FOR THE OTHER POST', 'delivered_footage', $3)`, [zone.id, other.id, f1.id]);
    await settle();
    assert.ok(!toasts().some((x) => x.includes('OTHER POST')));
    assert.equal(pill('footage-pill'), '');
  });
});
