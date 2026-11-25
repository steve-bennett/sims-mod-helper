const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'Code.gs'), 'utf8');

const AGENT = 'agent-token-aaaaaaaa';
const INSTALLER = 'installer-token-bbbb';

let uuidCounter = 0;
const scriptProps = {};
const ssBox = { sheet: null, inserted: 0 };
let lockFree = true;

const sandbox = {
  Utilities: { getUuid: () => 'row-' + ++uuidCounter },
  ContentService: {
    MimeType: { JSON: 'application/json' },
    createTextOutput: (text) => ({ text, mime: '', setMimeType(m) { this.mime = m; return this; } }),
  },
  LockService: {
    getScriptLock: () => ({ tryLock: () => lockFree, releaseLock: () => {} }),
  },
  SpreadsheetApp: {
    getActiveSpreadsheet: () => ({
      getSheetByName: (name) => (name === 'queue' ? ssBox.sheet : null),
      insertSheet: () => { ssBox.inserted++; ssBox.sheet = makeSheet(); return ssBox.sheet; },
    }),
  },
  PropertiesService: {
    getScriptProperties: () => ({ getProperty: (k) => (k in scriptProps ? scriptProps[k] : null) }),
  },
};
vm.runInNewContext(SRC, sandbox);

function makeSheet() {
  const rows = [];
  return {
    getDataRange: () => ({ getValues: () => rows.map((r) => r.slice()) }),
    appendRow: (arr) => { rows.push(arr.slice()); },
    getRange: (row, col, numRows, numCols) => ({
      setValues: (values) => {
        for (let i = 0; i < values.length; i++) {
          const target = row - 1 + i;
          if (!rows[target]) rows[target] = [];
          for (let j = 0; j < values[i].length; j++) rows[target][col - 1 + j] = values[i][j];
        }
      },
    }),
    dump: () => rows.map((r) => r.slice()),
  };
}

function propsWith(agent, installer) {
  return {
    getProperty: (k) => (k === 'AGENT_TOKEN' ? agent : k === 'INSTALLER_TOKEN' ? installer : null),
  };
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

function eq(actual, expected, msg) {
  assert(JSON.stringify(actual) === JSON.stringify(expected), msg + ' (got ' + JSON.stringify(actual) + ', want ' + JSON.stringify(expected) + ')');
}

function queue(sheet, props, action, args) {
  return sandbox.dispatch(sheet, props, Object.assign({ token: AGENT, action }, args));
}

let failures = 0;

function test(name, fn) {
  try {
    fn();
    console.log('PASS ' + name);
  } catch (err) {
    failures++;
    console.log('FAIL ' + name + ': ' + (err && err.message ? err.message : String(err)));
  }
}

test('agent-can-queue-install', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  const res = queue(sheet, props, 'queue_install', { projectId: 5, fileId: 9, modName: 'Nice Mod', requestedBy: 'parent' });
  assert(res.ok, 'result ok');
  const rows = sheet.dump();
  eq(rows[0], sandbox.HEADER, 'header row written');
  eq(rows[1][7], 'pending', 'status pending');
  eq(rows[1][2], 5, 'projectId stored');
  eq(rows[1][3], 9, 'fileId stored');
  eq(rows[1][0], res.id, 'row id matches result');
});

test('installer-cannot-queue', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  const res = sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'queue_install', projectId: 5, fileId: 9, modName: 'x', requestedBy: 'parent' });
  eq(res, { ok: false, error: 'not allowed' }, 'installer denied');
  eq(sheet.dump().length, 0, 'sheet untouched');
});

test('agent-cannot-report', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  const res = sandbox.dispatch(sheet, props, { token: AGENT, action: 'report', id: 'row-1', status: 'installed' });
  eq(res, { ok: false, error: 'not allowed' }, 'agent denied');
});

test('wrong-token', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  const res = sandbox.dispatch(sheet, props, { token: 'nope-nope-nope', action: 'queue_install', projectId: 5, fileId: 9, modName: 'x', requestedBy: 'parent' });
  eq(res, { ok: false, error: 'not allowed' }, 'wrong token denied');
  eq(sheet.dump().length, 0, 'sheet untouched');
});

test('empty-property-rejects', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, '');
  const res = sandbox.dispatch(sheet, props, { token: '', action: 'pending' });
  eq(res, { ok: false, error: 'not allowed' }, 'empty token and empty property denied');
  eq(sheet.dump().length, 0, 'sheet untouched');
});

test('pending-then-report', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  const made = queue(sheet, props, 'queue_install', { projectId: 5, fileId: 9, modName: 'Nice Mod', requestedBy: 'parent' });
  const waiting = sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'pending' });
  eq(waiting.rows.length, 1, 'pending lists the row');
  eq(waiting.rows[0].id, made.id, 'pending row id');
  const first = sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'report', id: made.id, status: 'installed', reason: '' });
  eq(first, { ok: true }, 'report accepted');
  eq(sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'pending' }).rows.length, 0, 'row left pending');
  const second = sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'report', id: made.id, status: 'failed', reason: 'retry' });
  eq(second.ok, false, 'second report refused');
});

test('unnotified-and-mark', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  const made = queue(sheet, props, 'queue_install', { projectId: 5, fileId: 9, modName: 'Nice Mod', requestedBy: 'parent' });
  sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'report', id: made.id, status: 'installed', reason: '' });
  const before = queue(sheet, props, 'unnotified', {});
  eq(before.rows.length, 1, 'reported row is unnotified');
  eq(queue(sheet, props, 'mark_notified', { ids: [made.id] }), { ok: true, count: 1 }, 'mark counted');
  eq(queue(sheet, props, 'unnotified', {}).rows.length, 0, 'row no longer unnotified');
});

test('formula-escaped', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  queue(sheet, props, 'queue_install', { projectId: 5, fileId: 9, modName: '=HYPERLINK("x")', requestedBy: 'parent' });
  const stored = sheet.dump()[1][4];
  assert(stored[0] === "'", 'leading quote added');
  eq(stored, '\'=HYPERLINK("x")', 'formula kept as text');
});

test('bad-int', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  const a = queue(sheet, props, 'queue_install', { projectId: '12a', fileId: 9, modName: 'x', requestedBy: 'parent' });
  eq(a.ok, false, 'text projectId rejected');
  const b = queue(sheet, props, 'queue_install', { projectId: -3, fileId: 9, modName: 'x', requestedBy: 'parent' });
  eq(b.ok, false, 'negative projectId rejected');
  eq(sheet.dump().length, 0, 'nothing written');
});

test('list-limit', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  for (let i = 1; i <= 250; i++) queue(sheet, props, 'queue_install', { projectId: i, fileId: i, modName: 'mod', requestedBy: 'parent' });
  const res = queue(sheet, props, 'list', { limit: 500 });
  eq(res.rows.length, 200, 'capped at 200');
  eq(res.rows[0].projectId, 250, 'newest first');
});

test('installed-latest-per-project', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  const install = queue(sheet, props, 'queue_install', { projectId: 5, fileId: 1, modName: 'A', requestedBy: 'parent' });
  sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'report', id: install.id, status: 'installed', reason: '' });
  const remove = queue(sheet, props, 'queue_uninstall', { projectId: 5, modName: 'A', requestedBy: 'parent' });
  sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'report', id: remove.id, status: 'uninstalled', reason: '' });
  const one = queue(sheet, props, 'installed', {});
  eq(one.rows.length, 1, 'one entry for project 5');
  eq(one.rows[0].status, 'uninstalled', 'latest status wins');

  const big = makeSheet();
  for (let i = 1; i <= 250; i++) {
    const row = queue(big, props, 'queue_install', { projectId: i, fileId: i, modName: 'mod', requestedBy: 'parent' });
    sandbox.dispatch(big, props, { token: INSTALLER, action: 'report', id: row.id, status: 'installed', reason: '' });
  }
  const all = queue(big, props, 'installed', {});
  eq(all.rows.length, 250, 'no limit across 250 projects');
});

test('unnotified-cap', () => {
  const sheet = makeSheet();
  const props = propsWith(AGENT, INSTALLER);
  for (let i = 1; i <= 25; i++) {
    const row = queue(sheet, props, 'queue_install', { projectId: i, fileId: i, modName: 'mod', requestedBy: 'parent' });
    sandbox.dispatch(sheet, props, { token: INSTALLER, action: 'report', id: row.id, status: 'installed', reason: '' });
  }
  const res = queue(sheet, props, 'unnotified', {});
  eq(res.rows.length, 20, 'capped at 20');
  eq(res.rows[0].projectId, 1, 'oldest first');
});

test('doPost-wired', () => {
  ssBox.sheet = null;
  ssBox.inserted = 0;
  scriptProps.AGENT_TOKEN = AGENT;
  scriptProps.INSTALLER_TOKEN = INSTALLER;
  const out = sandbox.doPost({ postData: { contents: JSON.stringify({ token: AGENT, action: 'queue_install', projectId: 7, fileId: 3, modName: 'Wire Test', requestedBy: 'parent' }) } });
  eq(out.mime, 'application/json', 'json mime type');
  const res = JSON.parse(out.text);
  assert(res.ok, 'round trip ok');
  assert(typeof res.id === 'string' && res.id.length > 0, 'id returned');
  eq(ssBox.inserted, 1, 'created the queue tab');
  eq(ssBox.sheet.dump()[0], sandbox.HEADER, 'header written');
  eq(ssBox.sheet.dump()[1][7], 'pending', 'row pending');
  const denied = JSON.parse(sandbox.doPost({ postData: { contents: JSON.stringify({ token: 'not-the-token', action: 'queue_install', projectId: 7, fileId: 3, modName: 'x', requestedBy: 'parent' }) } }).text);
  eq(denied, { ok: false, error: 'not allowed' }, 'wrong token denied through doPost');
  eq(ssBox.sheet.dump().length, 2, 'denied call wrote nothing beyond header and first row');
  const junk = JSON.parse(sandbox.doPost({ postData: { contents: '{not json' } }).text);
  eq(junk, { ok: false, error: 'bad request' }, 'bad json handled');
});

test('lock-busy', () => {
  ssBox.sheet = makeSheet();
  scriptProps.AGENT_TOKEN = AGENT;
  scriptProps.INSTALLER_TOKEN = INSTALLER;
  lockFree = false;
  const res = JSON.parse(sandbox.doPost({ postData: { contents: JSON.stringify({ token: AGENT, action: 'list' }) } }).text);
  lockFree = true;
  eq(res, { ok: false, error: 'busy, try again' }, 'lock timeout reported');
  eq(ssBox.sheet.dump().length, 0, 'nothing written');
});

console.log(failures ? failures + ' failed' : 'all passed');
process.exitCode = failures ? 1 : 0;
