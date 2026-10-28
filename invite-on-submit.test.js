// node invite-on-submit.test.js : runs invite-on-submit.gs against a mocked GitHub / Google (no network)
const vm = require('vm'), fs = require('fs'), assert = require('assert');
const src = fs.readFileSync(__dirname + '/invite-on-submit.gs', 'utf8');

function world(props) {
  const gh = { users: {}, members: {}, invitations: [], calls: [], nextId: 1 };
  const teams = ['Onlydevfans', 'Anvaya', 'Megabyte', 'Team Mayhem'].map(n => ({ name: n, slug: n.toLowerCase().replace(/ /g, '-') }));
  const rows = [['time', 'team', 'username', 'state', 'note']], mails = [];
  const res = (code, json) => ({ getResponseCode: () => code, getContentText: () => JSON.stringify(json) });
  const ctx = {
    Q: { team: 'Team name', people: ['Team leader', 'Member 1', 'Member 2', 'Member 3'].map(r => ({ name: r + ' - full name', gh: r + ' - GitHub username' })) },
    GH_RE: '^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$', Logger: { log() {} },
    PropertiesService: { getScriptProperties: () => ({ getProperty: k => props[k] }) },
    LockService: { getScriptLock: () => ({ waitLock() {}, releaseLock() {} }) },
    MailApp: { sendEmail: (to, subject, body) => mails.push({ to, subject, body }) },
    FormApp: { openById: () => ({ getDestinationId: () => 'ss' }) },
    SpreadsheetApp: { openById: () => ({ getSheetByName: () => ({ getDataRange: () => ({ getValues: () => rows.slice() }), appendRow: r => rows.push(r) }) }) },
    UrlFetchApp: { fetch(url, o) {
      const m = o.method, p = url.replace('https://api.github.com', ''); gh.calls.push(m + ' ' + p); let x;
      if ((x = p.match(/^\/users\/(.+)$/))) return gh.users[x[1].toLowerCase()] ? res(200, gh.users[x[1].toLowerCase()]) : res(404, { message: 'Not Found' });
      if (p.startsWith('/orgs/O/teams?')) return res(200, teams);
      if ((x = p.match(/^\/orgs\/O\/teams\/([^/]+)\/memberships\/(.+)$/))) {
        const s = (gh.members[x[1]] || {})[x[2].toLowerCase()];
        if (m === 'PUT') { const u = x[2].toLowerCase(), st = gh.users[u].member ? 'active' : 'pending'; (gh.members[x[1]] = gh.members[x[1]] || {})[u] = st; if (st === 'pending') gh.invitations.push({ id: gh.nextId++, login: x[2] }); return res(200, { state: st }); }
        return s ? res(200, { state: s }) : res(404, {});
      }
      if (p.startsWith('/orgs/O/invitations?')) return res(200, gh.invitations);
      if ((x = p.match(/^\/orgs\/O\/invitations\/(\d+)$/))) { gh.invitations = gh.invitations.filter(i => i.id != x[1]); return res(204, {}); }
      throw new Error('unmocked ' + m + ' ' + p);
    } },
  };
  vm.createContext(ctx); vm.runInContext(src, ctx);
  const submit = (team, people) => {
    const ans = { 'Team name': team }; ['Team leader', 'Member 1', 'Member 2', 'Member 3'].forEach((r, i) => { const p = people[i] || ['', 'NA']; ans[r + ' - full name'] = p[0]; ans[r + ' - GitHub username'] = p[1]; });
    vm.runInContext('handleResponse_(R)', Object.assign(ctx, { R: { getItemResponses: () => Object.keys(ans).map(k => ({ getItem: () => ({ getTitle: () => k }), getResponse: () => ans[k] })) } }));
    return mails[mails.length - 1];
  };
  const writes = () => gh.calls.filter(c => /^(PUT|DELETE)/.test(c));
  return { gh, rows, mails, submit, writes };
}
const user = (w, u, name, member) => { w.gh.users[u] = { type: 'User', name, member: !!member, login: u }; };
const run = (name, f) => { f(); console.log('ok   ' + name); };

run('dry run (default): reports, sends nothing, logs nothing', () => {
  const w = world({ ORG: 'O', FORM_ID: 'f', NOTIFY_EMAIL: 'me@x' }); user(w, 'a1', 'Alice Smith'); user(w, 'a2', 'Bob Jones');
  const m = w.submit('onlydevfans ', [['Alice Smith', 'a1'], ['Bob Jones', 'a2']]);
  assert.equal(w.writes().length, 0); assert.equal(w.rows.length, 1); assert(/DRY RUN/.test(m.subject) && /WOULD ADD/.test(m.body));
});
run('real run: invites both, logs pending, second submit is a no-op', () => {
  const w = world({ ORG: 'O', FORM_ID: 'f', NOTIFY_EMAIL: 'me@x', DRY_RUN: 'false' }); user(w, 'a1', 'Alice Smith'); user(w, 'a2', 'Bob Jones', true);
  let m = w.submit('Onlydevfans', [['Alice Smith', 'a1'], ['Bob Jones', 'a2']]);
  assert.equal(w.writes().length, 2); assert.deepEqual(w.rows.slice(1).map(r => r[3]), ['pending', 'active']); assert(!/\[CHECK\]/.test(m.subject));
  m = w.submit('Onlydevfans', [['Alice Smith', 'a1'], ['Bob Jones', 'a2']]);
  assert.equal(w.writes().length, 2); assert(/already pending/.test(m.body));
});
run('unknown team, alias, nonexistent user, bad username', () => {
  const w = world({ ORG: 'O', FORM_ID: 'f', NOTIFY_EMAIL: 'me@x', DRY_RUN: 'false' }); user(w, 'm1', 'Max Power');
  let m = w.submit('Nope', [['X Y', 'm1']]); assert.equal(w.writes().length, 0); assert(/UNKNOWN TEAM/.test(m.body) && /\[CHECK\]/.test(m.subject));
  m = w.submit('mayhem', [['Max Power', 'm1'], ['Ghost Man', 'ghost'], ['Bad Name', 'bad--name']]);
  assert.equal(w.writes().length, 1); assert(/NOT FOUND on GitHub: ghost/.test(m.body) && /BAD USERNAME/.test(m.body));
});
run('same username in two teams is refused', () => {
  const w = world({ ORG: 'O', FORM_ID: 'f', NOTIFY_EMAIL: 'me@x', DRY_RUN: 'false' }); user(w, 'a1', 'Alice Smith');
  w.submit('Onlydevfans', [['Alice Smith', 'a1']]); const m = w.submit('Megabyte', [['Alice Smith', 'a1']]);
  assert.equal(w.writes().length, 1); assert(/ALREADY IN TEAM "Onlydevfans"/.test(m.body));
});
run('latest submission wins: dropped pending invite is cancelled, dropped accepted person is flagged', () => {
  const w = world({ ORG: 'O', FORM_ID: 'f', NOTIFY_EMAIL: 'me@x', DRY_RUN: 'false' }); ['a1', 'a2', 'a3'].forEach(u => user(w, u, 'Alice Smith'));
  w.submit('Anvaya', [['Alice Smith', 'a1'], ['Alice Smith', 'a2']]);
  let m = w.submit('Anvaya', [['Alice Smith', 'a1'], ['Alice Smith', 'a3']]);
  assert(w.gh.calls.some(c => /^DELETE \/orgs\/O\/invitations\//.test(c))); assert(/CANCELLED pending invite for a2/.test(m.body));
  w.gh.members['anvaya'].a3 = 'active'; w.gh.invitations = [];   // a3 accepts, then the team resubmits without a3
  m = w.submit('Anvaya', [['Alice Smith', 'a1']]); assert(/MANUAL: a3 already ACCEPTED/.test(m.body));
});
run('profile name that does not match the form name is flagged', () => {
  const w = world({ ORG: 'O', FORM_ID: 'f', NOTIFY_EMAIL: 'me@x', DRY_RUN: 'false' }); user(w, 'z', 'Zed Quark');
  const m = w.submit('Megabyte', [['Alice Smith', 'z']]); assert(/differs/.test(m.body) && /\[CHECK\]/.test(m.subject));
});
console.log('all tests passed');
