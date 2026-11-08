// The browser half of tests/Test-Dashboard.ps1 (plan 08b): signs in to the Aspire dashboard as a dashboard-viewer with Microsoft Edge
// (playwright-core, no browser download) and checks, on several full page loads of Structured logs and Traces, that the tables show rows
// and that every given service has a row newer than the allowed age. Prints one line per check ("ok:" / "FAIL:") and exits 1 on a failure.
//
// Input (environment, set by Test-Dashboard.ps1; the password never appears on a command line or in the output):
//   DASHBOARD_URL         https://dashboard.daleabels.com
//   DASHBOARD_USER        admin@acme.test
//   DASHBOARD_PASSWORD    the demo users' password
//   DASHBOARD_LOG_SERVICES   requests-api (services that must have a fresh row on Structured logs)
//   DASHBOARD_TRACE_SERVICES requests-api (services that must have a fresh row on Traces)
//   DASHBOARD_TRACE_ROOT     gateway (the newest trace on each of those pages must start there: a request through the gateway)
//   DASHBOARD_MAX_AGE_MIN 10
//   DASHBOARD_LOADS       3 (full page loads per page)
//   DASHBOARD_NO_NUDGE    1: block /_procure/virtualize-nudge.js (shows whether the dashboard's tables load without the workaround)
//   DASHBOARD_IGNORE_TLS  1: accept any certificate (the local cluster's CA, when it is not trusted in Windows)
//   DASHBOARD_HEADED      1: show the browser
import { chromium } from 'playwright-core';

const base = (process.env.DASHBOARD_URL || '').replace(/\/$/, '');
const user = process.env.DASHBOARD_USER;
const password = process.env.DASHBOARD_PASSWORD;
const list = v => (v || '').split(',').map(s => s.trim()).filter(Boolean);
const servicesOf = { structuredlogs: list(process.env.DASHBOARD_LOG_SERVICES ?? 'requests-api'), traces: list(process.env.DASHBOARD_TRACE_SERVICES ?? 'requests-api') };
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
    return { found: true, rows, count: Math.max(0, Number(table.getAttribute('aria-rowcount')) - 1), headers, nudges };
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

// A cell's time of day (the dashboard shows HH:MM:SS.fff in the browser's time zone, the PC's) as minutes before `now`, the server's
// time from the page's Date header: the PC's clock may be off (Dale's ran 35 s ahead on 2026-11-08, Windows Time stopped).
function ageMinutes(text, now) {
  const m = /(\d{1,2}):(\d{2}):(\d{2})(?:\.\d+)?/.exec(text || '');
  if (!m) return null;
  const t = new Date(now);
  t.setHours(Number(m[1]), Number(m[2]), Number(m[3]), 0);
  let age = (now - t) / 60000;
  if (age < -1) age += 24 * 60; // before midnight
  return age;
}

const browser = await chromium.launch({ channel: 'msedge', headless: process.env.DASHBOARD_HEADED !== '1' });
try {
  const context = await browser.newContext({ ignoreHTTPSErrors: process.env.DASHBOARD_IGNORE_TLS === '1', viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();
  if (noNudge) await page.route('**/_procure/virtualize-nudge.js', route => route.abort());

  // 1. Sign in at Keycloak: user name first, then the password.
  await page.goto(`${base}/`);
  await page.locator('input[name=username]').fill(user);
  await page.locator('input[name=username]').press('Enter');
  await page.locator('input[name=password]').fill(password);
  await page.locator('input[name=password]').press('Enter');
  await page.waitForURL(u => u.toString().startsWith(base + '/'), { timeout: 30000 });
  ok(`signed in to ${base} as ${user}`);

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
      const response = await page.goto(`${base}/${name}/resource/${encodeURIComponent(service)}`, { waitUntil: 'load' });
      const serverDate = response && response.headers()['date'] ? new Date(response.headers()['date']) : null;
      const now = serverDate && !isNaN(serverDate) ? serverDate : new Date();
      const { grid, ms } = await waitForRows(page);
      if (ms === null) { fail(`/${name}/resource/${service}: no rows (grid ${grid.found ? `holds ${grid.count}` : 'not found'})`); continue; }
      const col = grid.headers.indexOf('Timestamp');
      const ages = grid.rows.map(r => ageMinutes(r[col], now)).filter(a => a !== null);
      const newest = ages.length ? Math.min(...ages) : null;
      if (newest !== null && newest <= maxAgeMin) ok(`/${name}/resource/${service}: newest row ${newest.toFixed(1)} min old (${grid.count} in all)`);
      else fail(`/${name}/resource/${service}: newest row ${newest === null ? 'has no time' : `${newest.toFixed(1)} min old`}, expected under ${maxAgeMin} min (${grid.count} in all)`);
      // Traces: the newest one is a request that came in through the gateway (its name is "<root resource>: <operation>").
      // (Not /traces/resource/gateway: on 13.6.2 that page stopped listing new gateway-rooted traces that the requests-api page lists.)
      if (name === 'traces' && traceRoot && newest !== null) {
        const nameCol = grid.headers.indexOf('Name');
        const newestRow = grid.rows.find(r => ageMinutes(r[col], now) === newest);
        const root = newestRow ? (newestRow[nameCol] || '').split(':')[0] : '';
        if (root === traceRoot) ok(`/${name}/resource/${service}: the newest trace starts at ${traceRoot} (${(newestRow[nameCol] || '').split(' ').slice(0, 3).join(' ')})`);
        else fail(`/${name}/resource/${service}: the newest trace starts at '${root}', expected ${traceRoot}`);
      }
    }
  }
} catch (e) {
  fail(`browser check stopped: ${e.message.split('\n')[0]}`);
} finally {
  await browser.close();
}
process.exit(failures ? 1 : 0);
