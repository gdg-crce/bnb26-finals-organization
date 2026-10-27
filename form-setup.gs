/**
 * Bit N Build 2026 Finals - team registration form
 *
 * 1. Go to script.google.com -> New project -> paste this whole file -> Save.
 * 2. Pick createForm in the function dropdown -> Run -> allow the permissions.
 * 3. Open View -> Logs (or Execution log): you get the form link (share this),
 *    the edit link and the responses sheet.
 * 4. After teams have filled it, run exportTeamsCsv. It checks for problems and
 *    drops a CSV in your Drive. Problems are listed in the execution log.
 */

const FORM_TITLE = 'Bit N Build 2026 Finals - Team Registration';

// GitHub usernames are 1-39 chars, letters/digits/hyphens, no leading or trailing hyphen.
// Apps Script uses RE2, so no lookaheads. "NA" is only accepted where a member can be missing.
const GH_RE    = '^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$';
const GH_RE_NA = '^([A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?|NA)$';

// Question titles are used again in exportTeamsCsv, keep them in one place.
const Q = {
  team: 'Team name',
  people: [
    { role: 'Team leader',   name: 'Team leader - full name',   gh: 'Team leader - GitHub username',   optional: false },
    { role: 'Member 1',      name: 'Member 1 - full name',      gh: 'Member 1 - GitHub username',      optional: false },
    { role: 'Member 2',      name: 'Member 2 - full name',      gh: 'Member 2 - GitHub username',      optional: true },
    { role: 'Member 3',      name: 'Member 3 - full name',      gh: 'Member 3 - GitHub username',      optional: true },
  ],
  confirm: 'Confirmation',
};

function createForm() {
  const form = FormApp.create(FORM_TITLE);
  form.setDescription(
    'Fill this once per team (team leader only). Teams have 2 to 4 members including the leader.\n\n' +
    'GitHub: enter the USERNAME only, not a link and not an email (example: octocat). ' +
    'Your repo access is granted to these accounts, so double check the spelling.\n' +
    'If your team has fewer than 4 people, type NA in the boxes for the missing members.'
  );
  form.setShowLinkToRespondAgain(false);
  form.setConfirmationMessage('Got it. Watch your email for the GitHub organization invite before the finals.');

  form.addTextItem().setTitle(Q.team).setRequired(true);

  Q.people.forEach(function (p) {
    form.addSectionHeaderItem()
        .setTitle(p.role)
        .setHelpText(p.optional ? 'Type NA in both boxes if your team has no ' + p.role.toLowerCase() + '.' : '');

    form.addTextItem().setTitle(p.name).setRequired(true);

    const rule = FormApp.createTextValidation()
      .setHelpText(p.optional
        ? 'Enter a GitHub username (no link, no @) or NA.'
        : 'Enter a GitHub username (no link, no @).')
      .requireTextMatchesPattern(p.optional ? GH_RE_NA : GH_RE)
      .build();
    form.addTextItem().setTitle(p.gh).setRequired(true).setValidation(rule);
  });

  form.addCheckboxItem()
      .setTitle(Q.confirm)
      .setChoiceValues(['I checked every GitHub username above. Access goes only to these accounts.'])
      .setRequired(true);

  // responses sheet
  const ss = SpreadsheetApp.create(FORM_TITLE + ' (responses)');
  form.setDestination(FormApp.DestinationType.SPREADSHEET, ss.getId());

  PropertiesService.getScriptProperties().setProperty('FORM_ID', form.getId());
  Logger.log('Share this link : ' + form.getPublishedUrl());
  Logger.log('Edit the form   : ' + form.getEditUrl());
  Logger.log('Responses sheet : ' + ss.getUrl());
}

/**
 * Reads all responses, checks them, writes teams.csv to Drive.
 * One row per person: team_name, github_username, full_name, role
 * Rules checked: same team submitted twice (latest wins), same GitHub username twice, same username in two teams.
 */
function exportTeamsCsv() {
  const id = PropertiesService.getScriptProperties().getProperty('FORM_ID');
  if (!id) throw new Error('Run createForm first (FORM_ID not found).');
  const form = FormApp.openById(id);

  const byTeam = {};     // key (lowercase team) -> {team, people[]}
  const problems = [];

  form.getResponses().forEach(function (resp) {   // oldest first, so later submissions overwrite
    const ans = {};
    resp.getItemResponses().forEach(function (ir) { ans[ir.getItem().getTitle()] = String(ir.getResponse()).trim(); });

    const team = (ans[Q.team] || '').replace(/\s+/g, ' ');
    if (!team) return;
    const key = team.toLowerCase();
    if (byTeam[key]) problems.push('Team "' + team + '" submitted more than once, using the latest.');

    const people = [];
    Q.people.forEach(function (p) {
      const gh = ans[p.gh] || '';
      const isNA = !gh || gh.toUpperCase() === 'NA';
      if (isNA && !p.optional) problems.push('Team "' + team + '": ' + p.role + ' has no GitHub username.');
      if (isNA) return;
      people.push({ role: p.role, name: ans[p.name] || '', gh: gh });
    });
    byTeam[key] = { team: team, people: people };
  });

  const seen = {};       // lowercase username -> team
  const rows = [['team_name', 'github_username', 'full_name', 'role']];
  Object.keys(byTeam).forEach(function (key) {
    const t = byTeam[key];
    if (t.people.length < 2) problems.push('Team "' + t.team + '" has only ' + t.people.length + ' member(s).');
    t.people.forEach(function (p) {
      const u = p.gh.toLowerCase();
      if (seen[u]) problems.push('@' + p.gh + ' appears in "' + seen[u] + '" and "' + t.team + '".');
      seen[u] = t.team;
      rows.push([t.team, p.gh, p.name, p.role]);
    });
  });

  const csv = rows.map(function (r) {
    return r.map(function (c) { return '"' + String(c).replace(/"/g, '""') + '"'; }).join(',');
  }).join('\n');
  const file = DriveApp.createFile('bnb26-teams.csv', csv, MimeType.CSV);

  Logger.log('Teams: ' + Object.keys(byTeam).length + ', people: ' + (rows.length - 1));
  Logger.log('CSV: ' + file.getUrl());
  Logger.log(problems.length ? 'PROBLEMS:\n' + problems.join('\n') : 'No problems found.');
}
