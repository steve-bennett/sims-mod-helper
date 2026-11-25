var HEADER = ['id', 'action', 'projectId', 'fileId', 'modName', 'requestedBy', 'requestedAt', 'status', 'reason', 'updatedAt', 'notified'];
var COL_ID = 1, COL_STATUS = 8, COL_REASON = 9, COL_UPDATED = 10, COL_NOTIFIED = 11;
var STATUSES = ['installed', 'blocked', 'failed', 'uninstalled'];
var DENY = { ok: false, error: 'not allowed' };

function doPost(e) {
  var result;
  try {
    var body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    result = handle(body);
  } catch (err) {
    result = { ok: false, error: 'bad request' };
  }
  return ContentService.createTextOutput(JSON.stringify(result)).setMimeType(ContentService.MimeType.JSON);
}

function doGet() {
  return ContentService.createTextOutput(JSON.stringify(DENY)).setMimeType(ContentService.MimeType.JSON);
}

function handle(body) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName('queue') || ss.insertSheet('queue');
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(10000)) return { ok: false, error: 'busy, try again' };
  try {
    return dispatch(sheet, PropertiesService.getScriptProperties(), body);
  } finally {
    lock.releaseLock();
  }
}

function dispatch(sheet, props, body) {
  body = body || {};
  var role = roleFor(props, body.token);
  if (!role) return DENY;
  var action = body.action;
  if (role === 'agent') {
    if (action === 'queue_install') return queueInstall(sheet, body);
    if (action === 'queue_uninstall') return queueUninstall(sheet, body);
    if (action === 'list') return list(sheet, body);
    if (action === 'unnotified') return unnotified(sheet);
    if (action === 'mark_notified') return markNotified(sheet, body);
    if (action === 'installed') return installed(sheet);
    return DENY;
  }
  if (action === 'pending') return pending(sheet);
  if (action === 'report') return report(sheet, body);
  return DENY;
}

function roleFor(props, token) {
  var agent = props.getProperty('AGENT_TOKEN') || '';
  var installer = props.getProperty('INSTALLER_TOKEN') || '';
  if (typeof token !== 'string' || token === '') return null;
  if (agent && sameSecret(token, agent)) return 'agent';
  if (installer && sameSecret(token, installer)) return 'installer';
  return null;
}

function sameSecret(a, b) {
  if (a.length !== b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function queueInstall(sheet, body) {
  var projectId = positiveInt(body.projectId);
  if (projectId === null) return { ok: false, error: 'projectId must be a positive whole number' };
  var fileId = positiveInt(body.fileId);
  if (fileId === null) return { ok: false, error: 'fileId must be a positive whole number' };
  return appendRow(sheet, 'install', projectId, fileId, clean(body.modName, 120), clean(body.requestedBy, 40));
}

function queueUninstall(sheet, body) {
  var projectId = positiveInt(body.projectId);
  if (projectId === null) return { ok: false, error: 'projectId must be a positive whole number' };
  return appendRow(sheet, 'uninstall', projectId, '', clean(body.modName, 120), clean(body.requestedBy, 40));
}

function appendRow(sheet, action, projectId, fileId, modName, requestedBy) {
  ensureHeader(sheet);
  var id = Utilities.getUuid();
  var now = new Date().toISOString();
  sheet.appendRow([id, action, projectId, fileId, modName, requestedBy, now, 'pending', '', now, '']);
  return { ok: true, id: id };
}

function list(sheet, body) {
  var limit = positiveInt(body.limit);
  if (limit === null) limit = 50;
  if (limit > 200) limit = 200;
  var rows = readRows(sheet).reverse();
  return { ok: true, rows: rows.slice(0, limit).map(publicRow) };
}

function unnotified(sheet) {
  var rows = readRows(sheet).filter(function (r) {
    return r.status !== 'pending' && r.notified === '';
  });
  return { ok: true, rows: rows.slice(0, 20).map(publicRow) };
}

function markNotified(sheet, body) {
  if (!Array.isArray(body.ids)) return { ok: false, error: 'ids must be a list of row ids' };
  var ids = body.ids.map(String);
  var now = new Date().toISOString();
  var count = 0;
  readRows(sheet).forEach(function (r) {
    if (r.notified === '' && ids.indexOf(r.id) >= 0) {
      sheet.getRange(r.row, COL_NOTIFIED, 1, 1).setValues([[now]]);
      count++;
    }
  });
  return { ok: true, count: count };
}

function pending(sheet) {
  return { ok: true, rows: readRows(sheet).filter(function (r) { return r.status === 'pending'; }).map(publicRow) };
}

function report(sheet, body) {
  var id = String(body.id === null || body.id === undefined ? '' : body.id).trim();
  if (id === '') return { ok: false, error: 'id is required' };
  if (STATUSES.indexOf(body.status) < 0) return { ok: false, error: 'status must be installed, blocked, failed or uninstalled' };
  var reason = clean(body.reason, 300);
  var rows = readRows(sheet);
  var target = null;
  for (var i = 0; i < rows.length; i++) if (rows[i].id === id) target = rows[i];
  if (!target) return { ok: false, error: 'no such row' };
  if (target.status !== 'pending') return { ok: false, error: 'that row is already reported' };
  sheet.getRange(target.row, COL_STATUS, 1, 3).setValues([[body.status, reason, new Date().toISOString()]]);
  return { ok: true };
}

function installed(sheet) {
  var latest = {};
  var order = [];
  readRows(sheet).forEach(function (r) {
    if (r.status === 'pending') return;
    var key = String(r.projectId);
    if (!latest.hasOwnProperty(key)) order.push(key);
    latest[key] = r;
  });
  return {
    ok: true,
    rows: order.map(function (key) {
      var r = latest[key];
      return { projectId: r.projectId, modName: r.modName, status: r.status, reason: r.reason, updatedAt: r.updatedAt };
    })
  };
}

function ensureHeader(sheet) {
  var data = sheet.getDataRange().getValues();
  var blank = data.length === 0 || data.every(function (row) {
    return row.every(function (cell) { return cell === '' || cell === null || cell === undefined; });
  });
  if (blank) sheet.getRange(1, 1, 1, HEADER.length).setValues([HEADER]);
}

function readRows(sheet) {
  var data = sheet.getDataRange().getValues();
  var rows = [];
  for (var i = 1; i < data.length; i++) {
    var r = data[i] || [];
    if (blankCell(r[0])) continue;
    rows.push({
      row: i + 1,
      id: String(r[0]),
      action: text(r[1]),
      projectId: cell(r[2]),
      fileId: cell(r[3]),
      modName: text(r[4]),
      requestedBy: text(r[5]),
      requestedAt: text(r[6]),
      status: text(r[7]),
      reason: text(r[8]),
      updatedAt: text(r[9]),
      notified: text(r[10])
    });
  }
  return rows;
}

function blankCell(v) {
  return v === '' || v === null || v === undefined;
}

function cell(v) {
  return blankCell(v) ? '' : v;
}

function text(v) {
  if (blankCell(v)) return '';
  return v instanceof Date ? v.toISOString() : String(v);
}

function publicRow(r) {
  var out = {};
  HEADER.forEach(function (k) { out[k] = r[k]; });
  return out;
}

function positiveInt(v) {
  var n = typeof v === 'string' ? (v.trim() === '' ? NaN : Number(v)) : v;
  return typeof n === 'number' && n > 0 && Math.floor(n) === n && isFinite(n) ? n : null;
}

function clean(v, max) {
  var s = v === null || v === undefined ? '' : String(v);
  s = s.trim();
  if (s.length > max) s = s.slice(0, max);
  if (/^[=+\-@]/.test(s)) s = "'" + s;
  return s;
}
