# Bit N Build 2026 Finals: GitHub org automation

Owner: Varad (GDG CRCE, runs ops for the Bit N Build hackathon). Casual, wants short answers and one script/block for shell tasks.
Files in this folder: `bnb26.sh`, `teams.sample.csv`, `form-setup.gs`, this file.

## Goal
Finals have 52 teams. Build a GitHub org where every team gets:
- its own repo (private, named after the team),
- access to ONLY that repo (write: clone + push),
- no way to see other teams or their repos,
- 2-3 council/organizer members with access to every repo, so cheating can be monitored.
Everything through the `gh` CLI. Needs a dry-run and a test setup.

## What exists (all written, NONE of it run against real GitHub yet)
- `bnb26.sh`: one script with modes `check | teams | repos | access | members | setup (= all four) [--dry-run] | audit | monitor | cleanup`. Auto-invite: `invite-on-submit.gs` (Apps Script form-submit trigger, same project as form-setup.gs; needs GH_TOKEN/NOTIFY_EMAIL/DRY_RUN script properties; logs to an "Invites" sheet seeded from `invites-seed.csv`; `node invite-on-submit.test.js` runs its mocked tests). Other `bnb26.sh` env: MEMBERS_CSV (hosted form csv), ONLY (team subset), SKIP_USERS, INVITE_CAP; `council` step. Output: coloured terminal lines + one `RESULT ok|wait|FAIL` line per team, plain log file, `events.tsv` (timestamped trail), and `status` (live: team/repo/access per team, who accepted / pending N days / expired, writes `not-accepted.tsv`). `teams.csv` (names only, 52 finalist teams from Varad's sheet, Finalist Team Name column) is enough for teams/repos/access; `members` needs `github_username`. Env config at the top of the file (ORG, CSV, COUNCIL, COUNCIL_PERM, REPO_SUFFIX, README_FILE, MAX_PER_TEAM, INVITE_CAP, SLEEP, OUT). Only tested against a fake `gh` stub (dry-run, bad CSVs, invite-failure pause, re-run skipping).
  Current behaviour: org settings, `GDG CRCE` (was GDG CRCE, slug gdg-crce) secret team, per team: secret team + private repo + seeded README/.gitignore + team gets `push` + council team gets COUNCIL_PERM + members added by **GitHub username** via `PUT teams/<slug>/memberships/<user>` (task 1 done: username-exists preflight, `audit` reports active/pending/missing per team; INVITE_CAP counts only users not yet in the org). Writes `repos.tsv` (with baseline commit SHA) and `invites.tsv`. `monitor` compares baseline to default branch (diverged/behind = history rewritten, force-push) and flags public repos. `cleanup` only runs on orgs with "test" in the name.
- `form-setup.gs`: Apps Script. `createForm()` builds the registration Google Form (team name, leader name + GitHub username, member 1, member 2, member 3, NA allowed for member 2/3, regex-validated usernames, confirmation checkbox, linked response sheet). `exportTeamsCsv()` dedupes and writes `bnb26-teams.csv` (team_name, github_username, full_name, role) to Drive and logs problems (team submitted twice, username in two teams, team under 2 people, NA in a required slot).

## Decisions made
- Org name: `BnB-26-Final-Round` (kept as `ORG` variable). The org "exists, just needs renaming" per Varad, but see open decisions.
- 1 team = 1 repo, strictly. Team permission on its repo = `push` (API word for write). Teams are `secret` so they can't see each other.
- Org base permission `none`, members can't create repos, private forks off.
- Repo name = `<TeamName>_Final-Round` with non `[A-Za-z0-9_-]` runs turned into `-`. No random trailing number (last year's was random 1-99, 7 collisions, not an ID).
- Council = one team `GDG CRCE` (was GDG CRCE, slug gdg-crce), 2-3 people, default `pull` on all repos (owners already have implicit admin).
- Participants register through the Google Form and give **GitHub usernames**, not emails.
- Repos are seeded with README (rules) + .gitignore (`.env`) so there is a baseline commit to detect history rewrites.

## Open decisions (ask Varad, do not guess)
1. Fresh org vs rename. Last year's org `BnB-25-Final-Round` still holds 48 repos, 48 teams, 127 members. Renaming keeps all of that (old members keep access, name collisions with returning teams) but the org is older than 1 month so invite limit is 500/24h. A fresh free org is clean but limited to 50 invites/24h for its first month (~208 invites = ~5 days, use `INVITE_CAP=50`). Wiping the old org is destructive: needs a dry-run cleanup script and explicit confirmation.
2. Council GitHub usernames and the permission level (pull vs triage/maintain/admin).
3. README rules text (current text in `bnb26.sh` is a generic placeholder).

## Next tasks for Claude Code
1. **Switch `bnb26.sh` from email invites to usernames.** CSV columns become `team_name,github_username,full_name,role` (the output of `exportTeamsCsv`). Keep the same validation (case-insensitive duplicate usernames, one username in one team, repo-name collisions, reserved `GDG CRCE` (was GDG CRCE, slug gdg-crce)).
   - Preflight: `gh api users/<name>` for every username, list the 404s and stop. Be gentle with rate limits (authenticated, 5000/h).
   - Per team: `PUT orgs/$ORG/teams/$slug/memberships/$user` with `{"role":"member"}`. For people not yet in the org this sends an org invitation (probably counts toward the daily invite limit); for existing members it adds them directly. Record the returned `.state` (active or pending) in `invites.tsv`.
   - Keep: INVITE_CAP, 3-failures-in-a-row pause, re-run skips done work, dry-run.
   - `audit`: per team compare CSV usernames with `GET orgs/$ORG/teams/$slug/memberships/$user` state; report active / pending / missing per team.
2. Test everything end to end on a throwaway org named like `BnB-26-Test` with 2 teams and Varad's own alt accounts. `./bnb26.sh cleanup` must only ever run there.
3. After the test passes, run for real only with Varad's go-ahead: `check`, then `setup --dry-run`, then `setup`, then `audit`.
4. Optional: a small `monitor` cron/loop wrapper that runs during the event and prints only flagged repos.

## Last year's org (BnB-25-Final-Round), read-only recon, key facts
- Free plan. Base permission none, members can't create repos, forking of private repos was allowed, 2FA not required (58 of 127 members had it off).
- 48 repos (46 private, 2 public), created empty, by script, ~15 s each. Names `<TeamName>_Final-Round_<N>`; one typo repo `Ma-2_FInal-Round_89`.
- 48 teams, all `closed` (not secret), strictly 1 team = 1 repo; 47 teams `write`, 1 team (`ma-2`) `read` by mistake.
- Organizers were 5 owners; 3 were also added as maintainers to every team.
- Participants: 122 org members on exactly one team each + 39 outside collaborators with direct write (mixed approaches). Cap was 4 participants per team. 7 teams had nobody on the team itself.
- No seeded README/rules; one repo had `.env` committed. No branch protection possible (Free plan, private repos).

## Gotchas (verified or from GitHub docs)
- Org creation is not possible through the CLI. Create or rename in the web UI.
- Token needs scopes `repo` and `admin:org` (`gh auth refresh -h github.com -s admin:org -s repo`); `delete_repo` only for test cleanup. The user running it must be an org **owner**.
- Org invites by email only work if the email matches a verified email on the invitee's GitHub account. That is why the form collects usernames.
- Invite limit: 50 per 24h if the org is under 1 month old and on Free, 500 otherwise.
- Free plan: no branch protection or rulesets on private repos, so teams with write can force-push. Detection only (`monitor`), not prevention. Enforcement would need a paid plan (not verified which tier).
- The team creator is added to the team as maintainer automatically.
- `gh api --paginate` has no `--slurp` in the installed version; the script pipes pages straight into `jq` instead.
- Some org settings are UI-only (member privilege toggles like repo deletion/visibility change); the script can't set them. Tell Varad to check Settings > Member privileges.

## Safety rules for this project
- Never run a mutating `gh` call against `BnB-25-Final-Round` (last year's data). Never run a real (non dry-run) `setup` or any destructive call on the real BnB-26 org without Varad saying so in the chat.
- Always `--dry-run` first. Never delete anything outside a `*test*` org.
- Do not paste participant usernames or emails into chat summaries; keep them in files.
- Keep answers short. One script, one block per shell task.
