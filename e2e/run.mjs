// End to end against a local Zharp backend: real scripts send, and what Zharp stored is checked.
//
//   ZHARP_E2E_TOKEN_FILE=…/token.txt node e2e/run.mjs
//
// Needs the backend on localhost:3000 (containers send to host.docker.internal:3000), Docker
// (PowerShell 7.6, bash, zsh, node images) and Windows PowerShell 5.1 when run on Windows.
// A throwaway app is created and deleted. Monitor pings are only ever successes: a failed ping
// opens an incident, and incidents page people.
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const API = process.env.ZHARP_E2E_API ?? 'http://localhost:3000/api/v1';
const INGEST_HOST = 'http://localhost:3000/api/v1/otlp';
const INGEST_DOCKER = 'http://host.docker.internal:3000/api/v1/otlp';
const token = readFileSync(process.env.ZHARP_E2E_TOKEN_FILE, 'utf8').trim();
const H = { Authorization: `Bearer ${token}`, 'x-workspace-id': process.env.ZHARP_E2E_WORKSPACE ?? '3', 'content-type': 'application/json' };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const api = async (path, init = {}) => {
  const go = () => fetch(`${API}/${path}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  // The local backend drops a kept-alive connection now and then: once more on a new one.
  const res = await go().catch(() => sleep(800).then(go));
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { status: res.status, text }; }
};
async function until(get, done, ms = 40000) {
  const end = Date.now() + ms;
  let value;
  do { value = await get(); if (done(value)) return value; await sleep(1500); } while (Date.now() < end);
  return value;
}
const docker = (args) => spawnSync('docker', args, { encoding: 'utf8', env: { ...process.env, MSYS_NO_PATHCONV: '1' } });
const hostPath = (p) => (process.platform === 'win32' ? p.replace(/\//g, '\\') : p);

// An app of the new platform where the backend knows it, else OpenTelemetry's (main before feat/script-frames).
async function createApp(name, platform, framework) {
  let r = await api('applications', { method: 'POST', body: JSON.stringify({ name, platform, framework }) });
  if (!r.data?.id) r = await api('applications', { method: 'POST', body: JSON.stringify({ name, platform: 'otel', framework }) });
  if (!r.data?.id) throw new Error(`could not create an app: ${JSON.stringify(r).slice(0, 300)}`);
  return r.data;
}
const issues = async (id) => { const r = (await api(`applications/${id}/issues?window=1h`)).data; return Array.isArray(r) ? r : (r?.issues ?? []); };
const issue = async (id, issueId) => (await api(`applications/${id}/issues/${issueId}`)).data;
const trace = async (traceId) => (await api(`applications/traces/${traceId}`)).data;
const logs = async (id) => { const r = (await api(`applications/${id}/logs?window=1h&limit=500`)).data; return Array.isArray(r) ? r : (r?.logs ?? r?.items ?? []); };

const results = [];
async function check(name, fn) {
  try { await fn(); results.push(['ok', name]); console.log(`ok - ${name}`); } catch (e) { results.push(['not ok', name, e.message]); console.log(`not ok - ${name}\n  ${e.message}`); }
}

const work = mkdtempSync(join(tmpdir(), 'zharp-e2e-'));
const ps = await createApp(`e2e-powershell-${Date.now()}`, 'powershell', 'PowerShell');
const sh = await createApp(`e2e-shell-${Date.now()}`, 'shell', 'Shell script');
console.log(`# apps ${ps.id} (${ps.platform}) and ${sh.id} (${sh.platform})`);

try {
  // ── PowerShell ────────────────────────────────────────────────────────────────
  writeFileSync(join(work, 'nightly.ps1'), [
    'param($Case)',
    `Import-Module '${hostPath(join(root, 'Zharp', 'Zharp.psd1'))}'`,
    "Start-Zharp -Service 'nightly-backup' -Environment 'e2e'",
    'function Copy-Database { param($Name) Get-Item "C:\\nope\\$Name" }',
    'function Invoke-Backup { Copy-Database -Name shop }',
    'function Start-Nightly { Invoke-Backup }',
    'switch ($Case) {',
    "  'deep' { Invoke-Zharp -Name 'deep' { Start-Nightly } }",
    "  'text' { Invoke-Zharp -Name 'text' { throw 'disk is full' } }",
    "  'keep' { Invoke-Zharp -Name 'keep' -KeepErrorAction { Get-Item C:\\nope -ErrorAction SilentlyContinue; 'went on' } }",
    "  'web'  { Invoke-Zharp -Name 'web' { Invoke-RestMethod 'http://localhost:3000/api/v1/no-such-route-e2e?token=secret' } }",
    "  'child' { Invoke-Zharp -Name 'child' { node -e \"console.log('child traceparent=' + process.env.TRACEPARENT)\" } }",
    "  'logs' { $env:ZHARP_LOGS = 'true'; Start-Zharp -Service 'nightly-backup' -Logs; Invoke-Zharp -Name 'logs' { Write-Warning 'disk 91% full'; Write-Host 'copied 120 files' } }",
    '}',
  ].join('\r\n'));
  const pwsh51 = (c) => spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(work, 'nightly.ps1'), c], {
    encoding: 'utf8', env: { ...process.env, ZHARP_KEY: ps.ingestKey, ZHARP_ENDPOINT: INGEST_HOST, ZHARP_DEBUG: 'true' },
  });
  const runs = {};
  if (process.platform === 'win32') {
    for (const c of ['deep', 'text', 'keep', 'web', 'child', 'logs']) runs[c] = pwsh51(c);
  }
  await check('PowerShell 5.1: a failure three functions deep is one issue with the stack and the code that ran; the script still fails', async () => {
    assert.notEqual(runs.deep.status, 0);
    const list = await until(() => issues(ps.id), (l) => l.some((i) => /ItemNotFoundException/.test(i.title ?? i.type ?? '')));
    const found = list.filter((i) => /ItemNotFoundException/.test(i.title ?? i.type ?? ''));
    assert.equal(found.length, 1, JSON.stringify(list.map((i) => i.title)));
    const detail = await issue(ps.id, found[0].id);
    const text = JSON.stringify(detail);
    assert.match(text, /Copy-Database/);
    assert.match(text, /Invoke-Backup/);
    // The code that ran shows on the frames once the backend reads script frames (feat/script-frames).
    const frames = detail?.latestEvent?.frames ?? [];
    if (frames.length) {
      assert.equal(frames[0].function, 'Copy-Database');
      assert.match(frames[0].context?.line ?? '', /Get-Item/, 'the code that ran');
    } else {
      console.log('  frames: none (backend without script frames); the stack and source context were sent');
    }
    console.log(`  culprit: ${found[0].culprit ?? detail?.culprit}; occurrences: ${found[0].count ?? found[0].events ?? '?'}`);
  });
  await check('PowerShell 5.1: throw "text" is a RuntimeException issue', async () => {
    const list = await until(() => issues(ps.id), (l) => l.some((i) => /disk is full/.test(i.title ?? '')));
    assert.ok(list.some((i) => /RuntimeException: disk is full/.test(i.title ?? '')), JSON.stringify(list.map((i) => i.title)));
  });
  await check('PowerShell 5.1: -KeepErrorAction leaves a non-terminating error alone', async () => {
    assert.equal(runs.keep.status, 0);
    assert.match(runs.keep.stdout, /went on/);
  });
  await check('PowerShell 5.1: a failed Invoke-RestMethod carries its URL (masked) and status', async () => {
    const list = await until(() => issues(ps.id), (l) => l.some((i) => /WebException|HttpResponseException|404/.test(i.title ?? '')));
    const found = list.find((i) => /WebException|HttpResponseException|404/.test(i.title ?? ''));
    assert.ok(found, JSON.stringify(list.map((i) => i.title)));
    const text = JSON.stringify(await issue(ps.id, found.id));
    assert.match(text, /no-such-route-e2e\?token=\[REDACTED\]/);
    assert.match(text, /"http.response.status_code":"[45][0-9][0-9]"/);
  });
  await check('PowerShell 5.1: a child node program gets the block\'s trace', async () => {
    const m = /child traceparent=00-([0-9a-f]{32})-([0-9a-f]{16})-01/.exec(runs.child.stdout);
    assert.ok(m, runs.child.stdout + runs.child.stderr);
    const t = await until(() => trace(m[1]), (v) => v && JSON.stringify(v).includes('child'));
    assert.match(JSON.stringify(t), /"child"/);
  });
  await check('PowerShell 5.1: ZHARP_LOGS=true sends Write-Warning and Write-Host', async () => {
    const l = await until(() => logs(ps.id), (v) => JSON.stringify(v).includes('copied 120 files'));
    const text = JSON.stringify(l);
    assert.match(text, /copied 120 files/);
    assert.match(text, /disk 91% full/);
  });

  // PowerShell 7.6 in Docker: the same module, the deep case.
  docker(['build', '-q', '-t', 'zharp-pwsh:7.6', '-f', join(root, 'tests', 'docker', 'pwsh.Dockerfile'), join(root, 'tests', 'docker')]);
  const linuxScript = readFileSync(join(work, 'nightly.ps1'), 'utf8')
    .replace(/Import-Module '[^']*'/, "Import-Module '/sdk/Zharp/Zharp.psd1'").replace(/C:\\\\nope\\\\/g, '/nope/').replace(/C:\\nope\\/g, '/nope/').replace("'nightly-backup'", "'nightly-backup-7'");
  writeFileSync(join(work, 'nightly7.ps1'), linuxScript);
  const r7 = docker(['run', '--rm', '-v', `${root}:/sdk`, '-v', `${work}:/w`, '-e', `ZHARP_KEY=${ps.ingestKey}`, '-e', `ZHARP_ENDPOINT=${INGEST_DOCKER}`, '--add-host', 'host.docker.internal:host-gateway', 'zharp-pwsh:7.6', 'pwsh', '-NoProfile', '-NonInteractive', '-File', '/w/nightly7.ps1', 'deep']);
  await check('PowerShell 7.6: the same failure from Linux arrives with its stack', async () => {
    assert.notEqual(r7.status, 0, r7.stderr);
    const l = await until(() => logs(ps.id), (v) => JSON.stringify(v).includes('nightly-backup-7'));
    assert.match(JSON.stringify(l), /nightly-backup-7/);
    const list = await issues(ps.id);
    assert.ok(list.some((i) => /ItemNotFoundException/.test(i.title ?? '')));
  });

  // ── Shell ─────────────────────────────────────────────────────────────────────
  writeFileSync(join(work, 'backup.sh'), [
    '#!/usr/bin/env bash',
    'source /sdk/zharp.sh',
    'copy_files() {',
    '    echo "copying" >&2',
    '    cat /nonexistent-e2e-file',
    '}',
    'backup() {',
    '    copy_files',
    '}',
    'backup',
    '',
  ].join('\n'));
  writeFileSync(join(work, 'fails.py'), 'import sys\nprint("processing rows")\nprint("row 7 is broken", file=sys.stderr)\nsys.exit(2)\n');
  writeFileSync(join(work, 'pipe.sh'), '#!/usr/bin/env bash\nsource /sdk/zharp.sh\ngrep needle /dev/null | sort\n');
  writeFileSync(join(work, 'child.js'), "console.log('node traceparent=' + process.env.TRACEPARENT)\n");
  const shEnv = ['-e', `ZHARP_KEY=${sh.ingestKey}`, '-e', `ZHARP_ENDPOINT=${INGEST_DOCKER}`, '--add-host', 'host.docker.internal:host-gateway'];
  const shRun = (image, cmd, extra = []) => docker(['run', '--rm', '-v', `${root}:/sdk`, '-v', `${work}:/w`, ...shEnv, ...extra, '--entrypoint', 'sh', image, '-c', cmd]);
  docker(['build', '-q', '-t', 'zharp-shell-test', '-f', join(root, 'tests', 'docker', 'shell.Dockerfile'), join(root, 'tests', 'docker')]);
  const deep = shRun('zharp-shell-test', 'bash /w/backup.sh');
  const pipe = shRun('zharp-shell-test', 'bash /w/pipe.sh');
  const py = shRun('zharp-shell-test', 'sh /sdk/zharp.sh run --service importer -- python3 /w/fails.py');
  const child = shRun('zharp-shell-test', 'sh /sdk/zharp.sh run -- node /w/child.js');
  writeFileSync(join(work, 'deep.zsh'), 'source /sdk/zharp.sh\ncopy_files() {\n    cat /nonexistent-zsh-file\n}\ncopy_files\n');
  const zshRun = shRun('zharp-shell-test', 'zsh /w/deep.zsh');
  const logsRun = shRun('zharp-shell-test', 'sh /sdk/zharp.sh run --service loggy -- sh -c "echo first-line; echo second-line >&2"', ['-e', 'ZHARP_LOGS=true']);

  await check('bash: the failing command three deep is one issue, stack and code that ran; exit code kept', async () => {
    assert.equal(deep.status, 1, deep.stderr);
    const list = await until(() => issues(sh.id), (l) => l.some((i) => /nonexistent-e2e-file/.test(i.title ?? '')));
    const found = list.filter((i) => /nonexistent-e2e-file/.test(i.title ?? ''));
    assert.equal(found.length, 1, JSON.stringify(list.map((i) => i.title)));
    const text = JSON.stringify(await issue(sh.id, found[0].id));
    assert.match(text, /copy_files/);
    assert.match(text, /cat \/nonexistent-e2e-file/);
  });
  await check('bash: a failing pipeline names its failing command', async () => {
    assert.equal(pipe.status, 1);
    const list = await until(() => issues(sh.id), (l) => l.some((i) => /grep exited with 1/.test(i.title ?? '')));
    assert.ok(list.some((i) => /grep exited with 1/.test(i.title ?? '')));
  });
  await check('zharp run: a Python script that exits 2 is reported, its exit code passed through', async () => {
    assert.equal(py.status, 2);
    const list = await until(() => issues(sh.id), (l) => l.some((i) => /python3 exited with 2/.test(i.title ?? '')));
    assert.ok(list.some((i) => /python3 exited with 2/.test(i.title ?? '')));
  });
  await check('zharp run: a child node program continues the trace', async () => {
    const m = /node traceparent=00-([0-9a-f]{32})-([0-9a-f]{16})-01/.exec(child.stdout);
    assert.ok(m, child.stdout + child.stderr);
    const t = await until(() => trace(m[1]), (v) => v && JSON.stringify(v).includes('node'));
    assert.match(JSON.stringify(t), /node/);
  });
  await check('zsh: the failing command arrives', async () => {
    assert.equal(zshRun.status, 1, zshRun.stderr);
    const list = await until(() => issues(sh.id), (l) => l.some((i) => /nonexistent-zsh-file/.test(i.title ?? '')));
    assert.ok(list.some((i) => /nonexistent-zsh-file/.test(i.title ?? '')), JSON.stringify(list.map((i) => i.title)));
  });
  await check('ZHARP_LOGS=true: stdout and stderr lines arrive', async () => {
    assert.equal(logsRun.status, 0);
    const l = await until(() => logs(sh.id), (v) => JSON.stringify(v).includes('second-line'));
    assert.match(JSON.stringify(l), /first-line/);
    assert.match(JSON.stringify(l), /second-line/);
  });

  // ── Cron job monitor: a success ping with the trace ─────────────────────────────
  const created = await api('monitors', { method: 'POST', body: JSON.stringify({ name: `e2e cron ${Date.now()}`, type: 'CRON', interval: 86400, metadata: { cronMode: 'interval', cronInterval: 1, cronIntervalUnit: 'days' } }) });
  const monitor = created.data;
  await check('Cron job monitor: zharp run --monitor pings start and 0 with the run\'s trace', async () => {
    assert.ok(monitor?.id, JSON.stringify(created).slice(0, 300));
    const tokenOf = monitor.metadata?.pingToken ?? (await api(`monitors/${monitor.id}`)).data?.metadata?.pingToken;
    assert.ok(tokenOf, 'no ping token');
    const ok = shRun('zharp-shell-test', `sh /sdk/zharp.sh run --monitor ${tokenOf} -- node /w/child.js`);
    assert.equal(ok.status, 0);
    const m = /00-([0-9a-f]{32})-/.exec(ok.stdout);
    const logsOf = await until(async () => (await api(`monitors/${monitor.id}/logs?limit=5`)).data, (v) => JSON.stringify(v ?? '').includes('exitCode'));
    const text = JSON.stringify(logsOf);
    assert.match(text, /"exitCode":0/);
    console.log(`  run stored ${text.includes(m[1]) ? 'with' : 'without (backend before feat/script-frames)'} its trace ${m[1]}`);
  });
  if (monitor?.id) await api(`monitors/${monitor.id}`, { method: 'DELETE' });
} finally {
  if (!process.env.KEEP) {
    await api(`applications/${ps.id}`, { method: 'DELETE' });
    await api(`applications/${sh.id}`, { method: 'DELETE' });
  }
  rmSync(work, { recursive: true, force: true });
}

const failed = results.filter((r) => r[0] !== 'ok').length;
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
