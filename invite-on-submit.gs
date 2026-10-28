/**
 * Bit N Build 2026 Finals - invite on form submit
 *
 * Paste this file into the SAME Apps Script project as form-setup.gs (it uses Q and GH_RE from there).
 *
 * Setup (one time):
 * 1. Project Settings -> Script properties, add:
 *      GH_TOKEN      classic token of the gdg-crce account, scope admin:org, expiry = a few days after the event
 *      NOTIFY_EMAIL  where the per-submission summary goes (comma separated)
 *      DRY_RUN       true   (nothing is sent to GitHub until you set it to false)
 *      ORG           BnB-26-Final-Round   (optional, this is the default)
 * 2. Run installTrigger once (allow the permissions).
 * 3. Test: submit the form once, or run replayLatest. You get an email saying what WOULD happen.
 *    Then set DRY_RUN to false.
 * 4. After the event: delete the trigger, revoke the token.
 *
 * What it does for every submission: matches the team to the finalist list, checks each username exists on GitHub,
 * adds each person to their team (GitHub sends the org invite; the team already has push on its own repo),
 * logs it in the "Invites" sheet and emails you the result. A team submitted twice = latest wins: people from the
 * earlier submission who are still pending and no longer listed get their invite cancelled.
 * It never touches the council team or anyone outside the form.
 */

const INVITE_LOG = 'Invites';   // sheet in the responses spreadsheet: time, team, username, state, note

// Finalist teams (+ other names teams may type). Generated from teams.csv.
const TEAMS = [
  {
    "name": "Onlydevfans"
  },
  {
    "name": "Anvaya"
  },
  {
    "name": "Beyond Binary"
  },
  {
    "name": "Visionaries"
  },
  {
    "name": "Chasma cube",
    "alias": [
      "Chashma Cube"
    ]
  },
  {
    "name": "Shellshock"
  },
  {
    "name": "Pookieblinders",
    "alias": [
      "PookieBlinder"
    ]
  },
  {
    "name": "Deploy for good"
  },
  {
    "name": "Megabyte"
  },
  {
    "name": "Jamy labs"
  },
  {
    "name": "Half_a_byte"
  },
  {
    "name": "Shift+Elite"
  },
  {
    "name": "Recursion"
  },
  {
    "name": "The Iterators"
  },
  {
    "name": "Epsilon Closure"
  },
  {
    "name": "Apexcode"
  },
  {
    "name": "ViSiON-QUEST"
  },
  {
    "name": "Team4i"
  },
  {
    "name": "CodeCrusaders"
  },
  {
    "name": "Insomnia"
  },
  {
    "name": "Dream67"
  },
  {
    "name": "Mac and Code"
  },
  {
    "name": "Enigma"
  },
  {
    "name": "Team Pony"
  },
  {
    "name": "Claude's Angels"
  },
  {
    "name": "Skill Issue"
  },
  {
    "name": "Karatsuba"
  },
  {
    "name": "Team Loondry"
  },
  {
    "name": "Thanda Paani"
  },
  {
    "name": "Flash256"
  },
  {
    "name": "welarp"
  },
  {
    "name": "overclocked"
  },
  {
    "name": "Team Revan"
  },
  {
    "name": "Ghee Khatam"
  },
  {
    "name": "d m e n s y a"
  },
  {
    "name": "Build & Break"
  },
  {
    "name": "Alpha"
  },
  {
    "name": "Cybar Mates",
    "alias": [
      "Cyber Mates"
    ]
  },
  {
    "name": "Tech Titans"
  },
  {
    "name": "Team Convergent"
  },
  {
    "name": "Mavens"
  },
  {
    "name": "Diamonds",
    "alias": [
      "Team Diamonds"
    ]
  },
  {
    "name": "Cookies"
  },
  {
    "name": "Build N Pray"
  },
  {
    "name": "Bumblebee",
    "alias": [
      "BumbleBees"
    ]
  },
  {
    "name": "404 - Jackpot",
    "alias": [
      "404 JACKPOT!"
    ]
  },
  {
    "name": "Quadcore",
    "alias": [
      "Quad Core"
    ]
  },
  {
    "name": "Notfound",
    "alias": [
      "teamNOTfound!"
    ]
  },
  {
    "name": "Gdg PCCE",
    "alias": [
      "GDG GOA"
    ]
  },
  {
    "name": "Team Mayhem",
    "alias": [
      "Mayahem",
      "Mayhem"
    ]
  },
  {
    "name": "Northh.Space"
  },
  {
    "name": "Pioneers"
  },
  {
    "name": "Drift"
  },
  {
    "name": "Paracetamol"
  },
  {
    "name": "_1"
  }
];

function installTrigger() {
  const id = prop_('FORM_ID');
  if (!id) throw new Error('Run createForm first (FORM_ID not found).');
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'onFormSubmit') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('onFormSubmit').forForm(FormApp.openById(id)).onFormSubmit().create();
  Logger.log('Trigger installed. DRY_RUN is "' + prop_('DRY_RUN') + '".');
}

function onFormSubmit(e) { handleResponse_(e.response); }

// Re-run the most recent response (respects DRY_RUN). Safe: people already invited are skipped.
function replayLatest() {
  const rs = FormApp.openById(prop_('FORM_ID')).getResponses();
  handleResponse_(rs[rs.length - 1]);
}

// ---------- internals ----------
function prop_(k) { return PropertiesService.getScriptProperties().getProperty(k) || ''; }
function norm_(s) { return String(s).toLowerCase().replace(/[^a-z0-9]/g, ''); }
function dry_() { return prop_('DRY_RUN').toLowerCase() !== 'false'; }   // anything but "false" = dry
function org_() { return prop_('ORG') || 'BnB-26-Final-Round'; }

function gh_(method, path, body) {
  const res = UrlFetchApp.fetch('https://api.github.com' + path, {
    method: method, muteHttpExceptions: true, contentType: 'application/json',
    headers: { Authorization: 'Bearer ' + prop_('GH_TOKEN'), Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' },
    payload: body ? JSON.stringify(body) : undefined
  });
  let json = null;
  try { json = JSON.parse(res.getContentText()); } catch (err) {}
  return { code: res.getResponseCode(), json: json };
}
// writes are skipped in a dry run
function write_(method, path, body) { return dry_() ? { code: 200, json: { state: 'dry' } } : gh_(method, path, body); }

function logSheet_() {
  const ss = SpreadsheetApp.openById(FormApp.openById(prop_('FORM_ID')).getDestinationId());
  return ss.getSheetByName(INVITE_LOG) || ss.insertSheet(INVITE_LOG);
}

function handleResponse_(resp) {
  const lock = LockService.getScriptLock();
  lock.waitLock(60000);
  const lines = [];
  let team = '?';
  try {
    const ans = {};
    resp.getItemResponses().forEach(function (ir) { ans[ir.getItem().getTitle()] = String(ir.getResponse()).trim(); });
    team = (ans[Q.team] || '').replace(/\s+/g, ' ');
    process_(team, ans, lines);
  } catch (err) {
    lines.push('ERROR: ' + err.message);
  } finally {
    lock.releaseLock();
  }
  notify_(team, lines);
}

function process_(teamIn, ans, lines) {
  const ORG = org_();
  const t = TEAMS.filter(function (x) {
    return [x.name].concat(x.alias || []).some(function (n) { return norm_(n) === norm_(teamIn); });
  })[0];
  if (!t) { lines.push('UNKNOWN TEAM "' + teamIn + '": nothing sent. Check the name or add an alias in TEAMS.'); return; }

  const gt = gh_('GET', '/orgs/' + ORG + '/teams?per_page=100');
  if (gt.code !== 200) throw new Error('could not list teams (HTTP ' + gt.code + '): check GH_TOKEN');
  const gteam = gt.json.filter(function (x) { return x.name.toLowerCase() === t.name.toLowerCase(); })[0];
  if (!gteam) { lines.push('TEAM "' + t.name + '" does not exist in the org yet: nothing sent.'); return; }

  // latest log row per team|username (rows are time, team, username, state, note)
  const sheet = logSheet_();
  const state = {};
  sheet.getDataRange().getValues().slice(1).forEach(function (r) { state[r[1] + '|' + String(r[2]).toLowerCase()] = r[3]; });
  const teamOf = {};   // username -> team, for people who are pending/active
  Object.keys(state).forEach(function (k) {
    if (state[k] === 'pending' || state[k] === 'active') teamOf[k.split('|')[1]] = k.split('|')[0];
  });
  const record = function (user, st, note) { if (!dry_()) sheet.appendRow([new Date(), t.name, user, st, note || '']); state[t.name + '|' + user.toLowerCase()] = st; };

  const people = Q.people.map(function (p) { return { name: ans[p.name] || '', gh: ans[p.gh] || '' }; })
    .filter(function (p) { return p.gh && p.gh.toUpperCase() !== 'NA'; });
  const wanted = {};
  people.forEach(function (p) { wanted[p.gh.toLowerCase()] = true; });

  // latest submission wins: drop people from an earlier submission who are no longer listed
  Object.keys(state).forEach(function (k) {
    const parts = k.split('|');
    if (parts[0] !== t.name || wanted[parts[1]]) return;
    if (state[k] === 'pending') {
      const inv = gh_('GET', '/orgs/' + ORG + '/invitations?per_page=100');
      const hit = (inv.json || []).filter(function (i) { return i.login && i.login.toLowerCase() === parts[1]; })[0];
      if (hit) {
        write_('DELETE', '/orgs/' + ORG + '/invitations/' + hit.id);
        record(parts[1], 'cancelled', 'not in the latest submission');
        lines.push('CANCELLED pending invite for ' + parts[1] + ' (not in the latest submission).');
      } else {   // no invitation left: they may have accepted since
        const m = gh_('GET', '/orgs/' + ORG + '/teams/' + gteam.slug + '/memberships/' + encodeURIComponent(parts[1]));
        if (m.code === 200 && m.json.state === 'active') {
          record(parts[1], 'active', 'accepted before the new submission');
          lines.push('MANUAL: ' + parts[1] + ' already ACCEPTED in ' + t.name + ' but is not in the latest submission. Remove them by hand if wrong.');
        } else {
          record(parts[1], 'cancelled', 'no longer invited');
        }
      }
    } else if (state[k] === 'active') {
      lines.push('MANUAL: ' + parts[1] + ' is already ACTIVE in ' + t.name + ' but not in the latest submission. Remove them by hand if wrong.');
    }
  });

  people.forEach(function (p) {
    const u = p.gh, key = t.name + '|' + u.toLowerCase();
    // the form pattern allows '--', GitHub does not
    if (!new RegExp(GH_RE).test(u) || u.indexOf('--') >= 0) { lines.push('BAD USERNAME ' + u + ' (' + p.name + '): skipped.'); return; }
    if (state[key] === 'pending' || state[key] === 'active') { lines.push('already ' + state[key] + ': ' + u); return; }
    if (teamOf[u.toLowerCase()] && teamOf[u.toLowerCase()] !== t.name) {
      lines.push('ALREADY IN TEAM "' + teamOf[u.toLowerCase()] + '": ' + u + ' skipped.'); return;
    }
    const gu = gh_('GET', '/users/' + encodeURIComponent(u));
    if (gu.code === 404) { lines.push('NOT FOUND on GitHub: ' + u + ' (' + p.name + '): skipped.'); return; }
    if (gu.code !== 200 || gu.json.type !== 'User') { lines.push('FAILED lookup of ' + u + ' (HTTP ' + gu.code + '): skipped.'); return; }
    const r = write_('PUT', '/orgs/' + ORG + '/teams/' + gteam.slug + '/memberships/' + encodeURIComponent(u), { role: 'member' });
    if (r.code !== 200) {
      lines.push('FAILED to add ' + u + ' (HTTP ' + r.code + ': ' + ((r.json && r.json.message) || '') + ')');
      record(u, 'failed', 'HTTP ' + r.code);
      return;
    }
    record(u, r.json.state);
    const flag = nameDiffers_(gu.json.name, p.name) ? '  <-- profile name "' + (gu.json.name || '') + '" differs from form name "' + p.name + '", check it is the right person' : '';
    lines.push((dry_() ? 'WOULD ADD ' : r.json.state.toUpperCase() + ': ') + u + ' (' + p.name + ')' + flag);
  });
}

// true when the GitHub profile name shares no word (3+ letters) with the name typed in the form
function nameDiffers_(profile, typed) {
  const words = function (s) { return String(s || '').toLowerCase().split(/[^a-z]+/).filter(function (w) { return w.length >= 3; }); };
  const a = words(profile), b = words(typed);
  if (!a.length || !b.length) return false;   // no profile name to compare
  return !a.some(function (w) { return b.indexOf(w) >= 0; });
}

function notify_(team, lines) {
  const to = prop_('NOTIFY_EMAIL');
  if (!to || !lines.length) return;
  const bad = lines.some(function (l) { return /UNKNOWN|NOT FOUND|ERROR|FAILED|MANUAL|ALREADY IN|BAD USERNAME|differs|CANCELLED/.test(l); });
  MailApp.sendEmail(to, (bad ? '[CHECK] ' : '') + 'BnB26 invites: ' + team + (dry_() ? ' (DRY RUN)' : ''), lines.join('\n'));
}
