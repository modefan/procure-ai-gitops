// The browser half of tests/Test-Dashboard.ps1 (plan 08b): signs in to the Aspire dashboard as a dashboard-viewer with Microsoft Edge
// (playwright-core, no browser download) and checks, on several full page loads of Structured logs and Traces, that the tables show rows
// and that every given service has a row newer than the allowed age. Prints one line per check ("ok:" / "FAIL:") and exits 1 on a failure.
//
// Input (environment, set by Test-Dashboard.ps1; the password never appears on a command line or in the output):
//   DASHBOARD_URL         https://dashboard.daleabels.com
//   DASHBOARD_USER        admin@acme.test
//   DASHBOARD_PASSWORD    the demo users' password
//   DASHBOARD_LOG_SERVICES   requests-api (services that must have a fresh row on Structured logs)
//   DASHBOARD_TRACE_SERVICES gateway,requests-api (services that must have a fresh row on Traces)
//   DASHBOARD_TRACE_ROOT     gateway (on each of those pages, some trace from the window must start there: a request through the gateway)
//   DASHBOARD_MAX_AGE_MIN 10
//   DASHBOARD_LOADS       3 (full page loads per page)
//   DASHBOARD_NO_NUDGE    1: block /_procure/virtualize-nudge.js (shows whether the dashboard's tables load without the workaround)
//   DASHBOARD_IGNORE_TLS  1: accept any certificate (the local cluster's CA, when it is not trusted in Windows)
//   DASHBOARD_HEADED      1: show the browser
//   DASHBOARD_BASIC_AUTH  1: the break-glass dashboard (plan 08b Task 4): DASHBOARD_USER / DASHBOARD_PASSWORD go to Traefik's basic-auth
//                         login (the browser's HTTP credentials) instead of Keycloak's sign-in form
//   DASHBOARD_RESOLVE     <ip>: send the dashboard's host name to this address (before its DNS record exists)
import { chromium } from 'playwright-core';

const base = (process.env.DASHBOARD_URL || '').replace(/\/$/, '');
const user = process.env.DASHBOARD_USER;
const password = process.env.DASHBOARD_PASSWORD;
const list = v => (v || '').split(',').map(s => s.trim()).filter(Boolean);
const servicesOf = { structuredlogs: list(process.env.DASHBOARD_LOG_SERVICES ?? 'requests-api'), traces: list(process.env.DASHBOARD_TRACE_SERVICES ?? 'gateway,requests-api') };
const traceRoot = process.env.DASHBOARD_TRACE_ROOT ?? 'gateway';
const maxAgeMin = Number(process.env.DASHBOARD_MAX_AGE_MIN || 10);
const loads = Number(process.env.DASHBOARD_LOADS || 3);
const noNudge = process.env.DASHBOARD_NO_NUDGE === '1';
// How long a table may stay without rows after a full page load. With the workaround it shows them within about 6 s (measured on the
// hosted VM from South Africa, 2026-11-08); without it a blank table stays blank.
const rowsTimeoutMs = 20000;

if (!base || !user || !password) {
  console.log('FAIL: DASHBOARD_URL, DASHBOARD_USER and DASHBOARD_PASSWORD must be set');
  process.exit(1);
}

let failures = 0;
const ok = m => console.log(`ok:   ${m}`);
const fail = m => { failures++; console.log(`FAIL: ${m}`); };

// The rows of the page's data grid: [cell texts] for every rendered body row, plus the grid's own row count and the nudges so far.
async function readGrid(page) {
  return page.evaluate(() => {
    const table = document.querySelector('table.fluent-data-grid');
    if (!table) return { found: false, rows: [], count: 0, headers: [] };
    const headers = [...table.querySelectorAll('thead th')].map(h => h.innerText.trim());
    const rows = [...table.querySelectorAll('tbody [role="row"]')].map(r => [...r.querySelectorAll('td')].map(td => td.innerText.trim()));
    const nudges = window.__procureVirtualizeNudge ? window.__procureVirtualizeNudge.nudges : null;
    const bodyRows = table.querySelectorAll('tbody [role="row"]');
    const lastIndex = bodyRows.length ? Number(bodyRows[bodyRows.length - 1].getAttribute('aria-rowindex')) : null;
    return { found: true, rows, count: Math.max(0, Number(table.getAttribute('aria-rowcount')) - 1), rowCount: Number(table.getAttribute('aria-rowcount')), lastIndex, headers, nudges };
  });
}

async function waitForRows(page) {
  const started = Date.now();
  let grid = { found: false, rows: [], count: 0 };
  while (Date.now() - started < rowsTimeoutMs) {
    grid = await readGrid(page);
    // An empty grid shows one "No ... found" row; only data counts.
    if (grid.count > 0 && grid.rows.length > 0) {
      const ms = Date.now() - started;
      // The first rows can be a partial render (seen: 5 of 74 traces, a count of 5 of 8 logs); read until two reads a second apart agree.
      const key = g => `${g.count}|${g.rows.length}|${JSON.stringify(g.rows[g.rows.length - 1])}`;
      for (let i = 0; i < 8; i++) {
        await page.waitForTimeout(1000);
        const next = await readGrid(page);
        const same = key(next) === key(grid);
        grid = next;
        if (same) break;
      }
      return { grid, ms };
    }
    await page.waitForTimeout(250);
  }
  return { grid, ms: null };
}

// A cell's time (with the context's locale pinned to en-US the dashboard shows h:MM:SS.fff AM/PM for today and M/D/YYYY h:MM:SS.fff
// AM/PM for older days, in the browser's time zone, the PC's) as minutes before `now`, the server's time from the page's Date header: the PC's
// clock may be off (Dale's ran 35 s ahead on 2026-11-08, Windows Time stopped). Reading only the time of day made yesterday's rows look
// a few hours old (2026-11-12: "11/11/2026 12:39" read as 12:39 today, a false "gateway traces 251 min old").
function ageMinutes(text, now) {
  const m = /(?:(\d{1,2})\/(\d{1,2})\/(\d{4})\s+)?(\d{1,2}):(\d{2}):(\d{2})(?:\.\d+)?(?:\s*([AP]M))?/i.exec(text || '');
  if (!m) return null;
  const t = new Date(now);
  if (m[3]) t.setFullYear(Number(m[3]), Number(m[1]) - 1, Number(m[2]));
  let hours = Number(m[4]);
  if (m[7]) hours = (hours % 12) + (m[7].toUpperCase() === 'PM' ? 12 : 0); // en-US shows 12-hour times: 12:05 AM is 00:05
  t.setHours(hours, Number(m[5]), Number(m[6]), 0);
  let age = (now - t) / 60000;
  if (!m[3] && age < -1) age += 24 * 60; // before midnight
  return age;
}

// The grids list the oldest row first and fill in over several Blazor round trips (seen on the hosted VM: 5 rows first, 113 a few
// seconds later), so the newest rows are there only once the grid is complete. Scrolls the grid (every scrollable ancestor and the
// window) to its end until the last rendered row is the grid's last row (aria-rowindex = aria-rowcount) and the count has held for
// five reads 1.5 s apart, at most 45 s. A partial first page can hold for several seconds (2026-11-12: the gateway page stayed at
// 5 of 115 rows for over 4.5 s), so each read first scrolls to the top and back and fires a resize, which makes Virtualize ask the
// server for its items again.
async function scrollGridToEnd(page) {
  let last = '', same = 0, grid = await readGrid(page);
  const started = Date.now();
  while (Date.now() - started < 45000) {
    await page.evaluate(async () => {
      const table = document.querySelector('table.fluent-data-grid');
      const scrollers = [];
      for (let e = table; e; e = e.parentElement) if (e.scrollHeight > e.clientHeight + 10) scrollers.push(e);
      for (const e of scrollers) e.scrollTop = 0;
      window.scrollTo(0, 0);
      await new Promise(r => setTimeout(r, 200));
      for (const e of scrollers) e.scrollTop = e.scrollHeight;
      window.scrollTo(0, document.body.scrollHeight);
      window.dispatchEvent(new Event('resize'));
    });
    await page.waitForTimeout(1500);
    grid = await readGrid(page);
    const complete = grid.lastIndex !== null && grid.lastIndex === grid.rowCount;
    const key = `${grid.rowCount}|${grid.lastIndex}|${JSON.stringify(grid.rows[grid.rows.length - 1])}`;
    same = complete && key === last ? same + 1 : 0;
    last = key;
    if (same >= 4) return grid;
  }
  return grid;
}

const basicAuth = process.env.DASHBOARD_BASIC_AUTH === '1';
const resolveTo = process.env.DASHBOARD_RESOLVE;
const launchArgs = resolveTo ? [`--host-resolver-rules=MAP ${new URL(base).hostname} ${resolveTo}`] : [];
const browser = await chromium.launch({ channel: 'msedge', headless: process.env.DASHBOARD_HEADED !== '1', args: launchArgs });
try {
  const context = await browser.newContext({ locale: 'en-US', ignoreHTTPSErrors: process.env.DASHBOARD_IGNORE_TLS === '1', viewport: { width: 1440, height: 900 },
    ...(basicAuth ? { httpCredentials: { username: user, password, origin: base } } : {}) });
  const page = await context.newPage();
  if (noNudge) await page.route('**/_procure/virtualize-nudge.js', route => route.abort());

  // 1. Sign in at Keycloak: user name first, then the password. The break-glass dashboard: the browser answers Traefik's basic-auth login.
  if (basicAuth) {
    const response = await page.goto(`${base}/`);
    if (!response || response.status() >= 400) fail(`${base}/ answered ${response ? response.status() : 'nothing'} with the basic-auth login`);
    else ok(`signed in to ${base} as ${user} (basic auth, no Keycloak)`);
  } else {
    await page.goto(`${base}/`);
    await page.locator('input[name=username]').fill(user);
    await page.locator('input[name=username]').press('Enter');
    await page.locator('input[name=password]').fill(password);
    await page.locator('input[name=password]').press('Enter');
    await page.waitForURL(u => u.toString().startsWith(base + '/'), { timeout: 30000 });
    ok(`signed in to ${base} as ${user}`);
  }

  // The Blazor circuit must be up (finding 1: every circuit was refused with 403 behind Traefik).
  let socket = false;
  page.on('websocket', ws => { if (ws.url().includes('/_blazor')) socket = true; });

  // 2. Full page loads of each page: the table shows rows.
  for (const name of ['structuredlogs', 'traces']) {
    for (let i = 1; i <= loads; i++) {
      socket = false;
      await page.goto(`${base}/${name}`, { waitUntil: 'load' });
      const { grid, ms } = await waitForRows(page);
      const nudged = grid.nudges === null || grid.nudges === undefined ? (noNudge ? 'workaround blocked' : 'workaround not loaded') : `${grid.nudges} nudge(s)`;
      if (ms !== null) ok(`/${name} load ${i}: ${grid.rows.length} rows shown after ${(ms / 1000).toFixed(1)} s of ${grid.count} (${nudged}, Blazor WebSocket ${socket ? 'open' : 'NOT seen'})`);
      else fail(`/${name} load ${i}: no rows after ${rowsTimeoutMs / 1000} s (grid ${grid.found ? `holds ${grid.count}` : 'not found'}; ${nudged}; Blazor WebSocket ${socket ? 'open' : 'NOT seen'})`);
    }
  }

  // 3. Each service has fresh rows: its own page (/structuredlogs/resource/<name>, /traces/resource/<name>), newest row's time.
  for (const name of ['structuredlogs', 'traces']) {
    for (const service of servicesOf[name]) {
      // A service that logs little (requests-api: one row per check run) can show a stale newest row when that row lands just after
      // the read, or when the grid is still partly drawn (2026-11-13: 209 min old, then 0.7 min on the next run). Read up to 3 times,
      // 10 s apart, reloading the page each time, before calling it stale.
      let grid = null, col = -1, now = new Date(), newest = null, noRows = null;
      for (let attempt = 1; attempt <= 3; attempt++) {
        if (attempt > 1) await page.waitForTimeout(10000);
        const response = await page.goto(`${base}/${name}/resource/${encodeURIComponent(service)}`, { waitUntil: 'load' });
        const serverDate = response && response.headers()['date'] ? new Date(response.headers()['date']) : null;
        now = serverDate && !isNaN(serverDate) ? serverDate : new Date();
        const loaded = await waitForRows(page);
        if (loaded.ms === null) { noRows = loaded; continue; }
        noRows = null;
        grid = await scrollGridToEnd(page);
        col = grid.headers.indexOf('Timestamp');
        const ages = grid.rows.map(r => ageMinutes(r[col], now)).filter(a => a !== null);
        newest = ages.length ? Math.min(...ages) : null;
        if (newest !== null && newest <= maxAgeMin) break;
      }
      if (noRows) { fail(`/${name}/resource/${service}: no rows (grid ${noRows.grid.found ? `holds ${noRows.grid.count}` : 'not found'})`); continue; }
      if (newest !== null && newest <= maxAgeMin) ok(`/${name}/resource/${service}: newest row ${newest.toFixed(1)} min old (${grid.count} in all)`);
      else fail(`/${name}/resource/${service}: newest row ${newest === null ? 'has no time' : `${newest.toFixed(1)} min old`}, expected under ${maxAgeMin} min (${grid.count} in all)`);
      // Traces: some trace from the window is a request that came in through the gateway (its name is "<root resource>: <operation>").
      // Not only the newest one: a message or job trace may land between this check's own request and the page read (review I2).
      if (name === 'traces' && traceRoot) {
        const nameCol = grid.headers.indexOf('Name');
        const recent = grid.rows.filter(r => { const a = ageMinutes(r[col], now); return a !== null && a <= maxAgeMin; });
        const hit = recent.find(r => (r[nameCol] || '').split(':')[0] === traceRoot);
        if (hit) ok(`/${name}/resource/${service}: ${recent.length} trace(s) from the last ${maxAgeMin} min, one starts at ${traceRoot} (${(hit[nameCol] || '').split(' ').slice(0, 3).join(' ')})`);
        else fail(`/${name}/resource/${service}: none of the ${recent.length} trace(s) from the last ${maxAgeMin} min starts at ${traceRoot}`);
      }
    }
  }
} catch (e) {
  fail(`browser check stopped: ${e.message.split('\n')[0]}`);
} finally {
  await browser.close();
}
process.exit(failures ? 1 : 0);
