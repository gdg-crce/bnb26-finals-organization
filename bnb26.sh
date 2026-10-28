#!/usr/bin/env bash
# bnb26.sh - Bit N Build 2026 finals: GitHub org setup (teams, repos, invites, audit)
#
#   ./bnb26.sh check              validate CSV + GitHub usernames + org access, print the plan, change nothing
#   ./bnb26.sh teams   [--dry-run] org settings, council team, 1 secret team per team (no members, no usernames needed)
#   ./bnb26.sh repos   [--dry-run] 1 private repo per team, seeded README + .gitignore (baseline commit for monitor)
#   ./bnb26.sh access  [--dry-run] team -> its own repo (push), council team -> every repo (COUNCIL_PERM)
#   ./bnb26.sh members [--dry-run] add people by GitHub username (needs github_username in the CSV; sends org invites)
#   ./bnb26.sh council [--dry-run] add ONLY the council members (COUNCIL / council.txt) to the org + the council team (COUNCIL_TEAM)
#   ./bnb26.sh setup   [--dry-run] teams + repos + access + members in one go, per team
#   ./bnb26.sh status             live view per team: team/repo/access ok? who accepted, who is pending, missing or expired
#   ./bnb26.sh audit              verify settings, visibility, team->repo access, council access, per-team member state
#   ./bnb26.sh monitor            history check per repo (baseline commit vs default branch), last push
#   ./bnb26.sh cleanup            TEST ORGS ONLY (org name must contain "test"): deletes every repo, team, pending invite
#
# Config (env vars, defaults in brackets):
#   ORG [BnB-26-Final-Round]   CSV [teams.csv]  (columns: team_name[,github_username,full_name,role])
#   MEMBERS_CSV [none]         form responses (file or https URL, e.g. the published Google Sheet csv): usernames per team.
#                              Teams are matched to the finalist list in CSV by name (or its registered_name column); a team
#                              submitted twice = latest wins; a form team that matches nothing stops the run.
#   ONLY [all]                 limit the run to these teams, comma separated, e.g. ONLY="Insomnia,Mac and Code"
#   SKIP_USERS [none]          usernames to leave out, comma separated (their team mates are still added)
#   COUNCIL ["" ]              comma separated GitHub usernames, e.g. "user1,user2,user3"
#   COUNCIL_PERM [pull]        pull | triage | push | maintain | admin
#   REPO_SUFFIX [_Final-Round] repo name = <TeamName>_Final-Round
#   README_FILE [built-in]     path to your own README template ({{TEAM}} gets replaced)
#   MAX_PER_TEAM [4]           warn if a team has more people than this
#   INVITE_CAP [0]             max NEW org invites per run (0 = no cap). Existing org members are added without limit.
#                              Free org younger than 1 month: 50 invites per 24h
#   SLEEP [3]                  seconds between teams
#   OUT [./out-<ORG>]          where logs / tsv files go
#
# Needs: gh (logged in as an org OWNER, scopes: repo, admin:org), jq, python3, base64

set -uo pipefail

ORG="${ORG:-BnB-26-Final-Round}"
CSV="${CSV:-teams.csv}"   # file or https URL
MEMBERS_CSV="${MEMBERS_CSV:-}"
ONLY="${ONLY:-}"
COUNCIL="${COUNCIL:-$(grep -v '^#' council.txt 2>/dev/null | tr -s ' \n' ',' | sed 's/,$//')}"   # default: council.txt, one username per line
COUNCIL_PERM="${COUNCIL_PERM:-pull}"
REPO_SUFFIX="${REPO_SUFFIX:-_Final-Round}"
README_FILE="${README_FILE:-}"
MAX_PER_TEAM="${MAX_PER_TEAM:-4}"
INVITE_CAP="${INVITE_CAP:-0}"
SLEEP="${SLEEP:-3}"
OUT="${OUT:-./out-${ORG}}"
COUNCIL_TEAM="${COUNCIL_TEAM:-GDG CRCE}"   # team name; its slug is looked up, never assumed

CMD="${1:-help}"; shift || true
DRY=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; done

mkdir -p "$OUT"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$OUT/run-$STAMP.log"
FAILS=()
INV_SENT=0; INV_SKIP=0; INV_FAIL=0; INV_STREAK=0; INV_BLOCKED=0; INV_CAPPED=0
ME=""; STEPS=""
M_ACT=0; M_PEND=0; M_FAIL=0; M_WAIT=0; REPO_STATE=""
C1=0; C2=0   # colour on stdout / stderr only when they are a terminal (NO_COLOR=1 turns it off)
[ -z "${NO_COLOR:-}" ] && { [ -t 1 ] && C1=1; [ -t 2 ] && C2=1; }

# ---------- helpers (all logging goes to stderr so $(...) captures stay clean) ----------
paint() { if [ "$C1" = 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
log() {  # terminal: coloured by keyword. log file: always plain.
  local line c=0; line="$(date +%T) $*"; printf '%s\n' "$line" >> "$LOG"
  case "$*" in
    DRY*) c=2;;
    *FAIL*|ERROR*) c=31;;
    *"RESULT wait"*|*WARN*|*pending*|*Pausing*|*"invite cap"*|*"rate limited"*) c=33;;
    *"RESULT ok"*|*created*|*": active"*|*seeded*|*PASS*|*"== done"*) c=32;;
    *exists*|*skipped*|*already*) c=2;;
  esac
  if [ "$C2" = 1 ] && [ "$c" != 0 ]; then printf '\033[%sm%s\033[0m\n' "$c" "$line" >&2; else printf '%s\n' "$line" >&2; fi
}
die()  { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

# read-only GET. prints body, non-zero on 404/etc.
get() { gh api "$@" 2>/dev/null </dev/null; }

# mutating call: mut METHOD PATH [json-body]. Prints response (or error text) on stdout.
mut() {
  local method=$1 path=$2 body=${3:-} try out rc
  if [ "$DRY" = 1 ]; then
    log "DRY  $method $path ${body:+$(printf '%s' "$body" | jq -c . 2>/dev/null)}"
    echo '{"id":0,"slug":"dry-run","commit":{"sha":"0000000000000000000000000000000000000000"}}'
    return 0
  fi
  for try in 1 2 3; do
    if [ -n "$body" ]; then out=$(printf '%s' "$body" | gh api -X "$method" "$path" --input - 2>&1); rc=$?
    else out=$(gh api -X "$method" "$path" 2>&1 </dev/null); rc=$?; fi
    if [ $rc -eq 0 ]; then printf '%s' "$out"; return 0; fi
    if printf '%s' "$out" | grep -qiE 'secondary rate limit|abuse detection|HTTP 429'; then
      log "  rate limited, sleeping 60s (try $try/3)"; sleep 60; continue
    fi
    printf '%s' "$out"; return $rc
  done
  printf '%s' "$out"; return 1
}

# durable event trail (real runs only): time, step, team, item, status, detail
ev() { [ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$STEPS" "$1" "$2" "$3" "${4:-}" >> "$OUT/events.tsv"; }

errmsg() { printf '%s' "$1" | jq -r '.message // empty' 2>/dev/null | head -c 160 || true; }

# local path for a file or an https URL (downloaded into $OUT)
fetch_src() {  # value name
  case "$1" in
    http://*|https://*) curl -fsSL --max-time 60 -o "$OUT/$2" "$1" || die "could not download $2"; log "downloaded $2 ($(wc -c < "$OUT/$2") bytes)"; printf '%s' "$OUT/$2";;
    *) printf '%s' "$1";;
  esac
}

# ---------- CSV -> members.tsv (team \t github_username \t repo) ----------
load_csv() {
  local csv_local mem_local=""
  csv_local=$(fetch_src "$CSV" fetched-teams.csv) || exit 1
  [ -f "$csv_local" ] || die "CSV not found: $CSV"
  if [ -n "$MEMBERS_CSV" ]; then mem_local=$(fetch_src "$MEMBERS_CSV" fetched-members.csv) || exit 1; [ -f "$mem_local" ] || die "MEMBERS_CSV not found: $MEMBERS_CSV"; fi
  python3 -I - "$csv_local" "$REPO_SUFFIX" "$MAX_PER_TEAM" "$COUNCIL_TEAM" "$mem_local" "${ONLY:-}" > "$OUT/members.tsv" <<'PY'
import csv, re, sys
path, suffix, maxn, reserved, members_path, only = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
rd = csv.reader(open(path, encoding="utf-8-sig", newline=""))
rows = [(rd.line_num, r) for r in rd if any(c.strip() for c in r)]
if not rows: sys.exit("CSV is empty")
hdr = [c.strip().lower().replace(" ", "_") for c in rows[0][1]]
ti = next((i for i, h in enumerate(hdr) if h in ("team", "team_name")), None)
ui = next((i for i, h in enumerate(hdr) if h in ("github_username", "username", "github")), None)
ai = next((i for i, h in enumerate(hdr) if h in ("registered_name", "alias")), None)
if ti is None:
    sys.exit("header must have a team_name column, got: %s" % hdr)
GH = re.compile(r"[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?")
errs, teams, user_team, repos = [], {}, {}, {}
for ln, r in rows[1:]:
    if len(r) <= max(ti, ui or 0): errs.append("line %d: too few columns" % ln); continue
    team = re.sub(r"\s+", " ", r[ti]).strip(); user = r[ui].strip() if ui is not None else ""
    if not team or (ui is not None and not user): errs.append("line %d: empty team or username" % ln); continue
    if user and (not GH.fullmatch(user) or "--" in user):
        errs.append("line %d: bad GitHub username %r (username only, no @, no link)" % (ln, user)); continue
    key, ukey = team.casefold(), user.casefold()
    if key == reserved.casefold(): errs.append("line %d: team name %r is reserved" % (ln, team)); continue
    t = teams.setdefault(key, {"name": team, "users": [], "alias": set()})
    if t["name"] != team: errs.append("line %d: team %r also written as %r" % (ln, team, t["name"]))
    if ai is not None and ai < len(r):
        for a in r[ai].split("|"):
            if a.strip(): t["alias"].add(re.sub(r"\s+", " ", a).strip())
    if not user: continue
    if ukey in user_team and user_team[ukey] != key:
        errs.append("line %d: %s is in two teams (%s, %s)" % (ln, user, teams[user_team[ukey]]["name"], team)); continue
    user_team[ukey] = key
    if ukey not in [u.casefold() for u in t["users"]]: t["users"].append(user)
if members_path:   # form responses: one row per team, "<role> - GitHub username" columns
    mr = list(csv.reader(open(members_path, encoding="utf-8-sig", newline="")))
    mh = [c.strip() for c in mr[0]] if mr else []
    mt = next((i for i, h in enumerate(mh) if h.lower() in ("team name", "team", "team_name")), None)
    gcols = [i for i, h in enumerate(mh) if re.fullmatch(r".*github username", h, re.I)]
    if mt is None or not gcols: sys.exit("MEMBERS_CSV needs a 'Team name' column and '<role> - GitHub username' columns, got: %s" % mh)
    norm = lambda x: re.sub(r"[^a-z0-9]", "", x.casefold())
    index = {}
    for key, t in teams.items():
        index[norm(t["name"])] = key
        for a in t["alias"]: index.setdefault(norm(a), key)
    latest = {}
    for n, r in enumerate(mr[1:], start=2):
        name = re.sub(r"\s+", " ", r[mt]).strip() if mt < len(r) else ""
        if not name: continue
        key = index.get(norm(name))
        if key is None:
            if only: sys.stderr.write("WARN: form row %d: team %r matches no finalist team, skipped (ONLY is set)\n" % (n, name))
            else: errs.append("form row %d: team %r matches no finalist team (fix the sheet or add registered_name)" % (n, name))
            continue
        if key in latest: sys.stderr.write("WARN: team %r submitted again (form row %d), using the latest\n" % (teams[key]["name"], n))
        latest[key] = r
    for key, r in latest.items():
        t = teams[key]
        for gi in gcols:
            user = r[gi].strip() if gi < len(r) else ""
            if not user or user.upper() == "NA": continue
            if not GH.fullmatch(user) or "--" in user:
                errs.append("form team %r: bad GitHub username %r (username only, no @, no link)" % (t["name"], user)); continue
            ukey = user.casefold()
            if ukey in user_team and user_team[ukey] != key:
                errs.append("form: %s is in two teams (%s, %s)" % (user, teams[user_team[ukey]]["name"], t["name"])); continue
            user_team[ukey] = key
            if ukey not in [u.casefold() for u in t["users"]]: t["users"].append(user)
for key, t in teams.items():
    repo = re.sub(r"-+", "-", re.sub(r"[^A-Za-z0-9_-]+", "-", t["name"].replace("'", "").replace("’", ""))).strip("-") + suffix   # ' is dropped, other symbols become -
    if repo.startswith("-") or len(repo) > 100 or repo.strip("-_") == suffix.strip("-_"):
        errs.append("team %r gives a bad repo name %r" % (t["name"], repo))
    if repo.casefold() in repos: errs.append("teams %r and %r give the same repo %r" % (repos[repo.casefold()], t["name"], repo))
    repos[repo.casefold()] = t["name"]; t["repo"] = repo
    if len(t["users"]) > maxn:
        sys.stderr.write("WARN: team %r has %d members (max %d)\n" % (t["name"], len(t["users"]), maxn))
if errs:
    sys.stderr.write("\n".join("CSV ERROR: " + e for e in errs) + "\n"); sys.exit(1)
for t in teams.values():
    for u in t["users"] or [""]: print("%s\t%s\t%s" % (t["name"], u, t["repo"]))
sys.stderr.write("CSV ok: %d teams, %d members, %d teams have no usernames yet\n" % (len(teams), sum(len(t["users"]) for t in teams.values()), sum(1 for t in teams.values() if not t["users"])))
PY
  [ "${PIPESTATUS[0]}" = 0 ] || die "CSV validation failed (see above)"
  if [ -n "${SKIP_USERS:-}" ]; then   # leave these usernames out (e.g. a typo waiting for a fix); the rest of their team is still added
    awk -F'\t' -v skip="$SKIP_USERS" 'BEGIN{n=split(tolower(skip),a,",");for(i=1;i<=n;i++){gsub(/^ +| +$/,"",a[i]);s[a[i]]=1}} !($2!="" && (tolower($2) in s))' "$OUT/members.tsv" > "$OUT/members.tsv.tmp" && mv "$OUT/members.tsv.tmp" "$OUT/members.tsv"
    log "SKIP_USERS: left out $(tr ',' '\n' <<<"$SKIP_USERS" | wc -l) username(s)"
  fi
  if [ -n "${ONLY:-}" ]; then   # work on the listed teams only (names as in teams.csv, comma separated)
    local o; while IFS= read -r o; do
      [ -n "$o" ] && { team_names | grep -qixF "$o" || die "ONLY: no such team '$o'"; }
    done < <(tr ',' '\n' <<<"$ONLY" | sed 's/^ *//; s/ *$//')
    awk -F'\t' -v only="$ONLY" 'BEGIN{n=split(tolower(only),a,",");for(i=1;i<=n;i++){gsub(/^ +| +$/,"",a[i]);s[a[i]]=1}} s[tolower($1)]' "$OUT/members.tsv" > "$OUT/members.tsv.tmp" && mv "$OUT/members.tsv.tmp" "$OUT/members.tsv"
    log "ONLY: limited to $(team_names | wc -l) team(s): $ONLY"
  fi
}
team_names() { cut -f1 "$OUT/members.tsv" | awk '!s[$0]++'; }
users_of()   { awk -F'\t' -v t="$1" '$1==t && $2!=""{print $2}' "$OUT/members.tsv"; }
repo_of()    { awk -F'\t' -v t="$1" '$1==t{print $3; exit}' "$OUT/members.tsv"; }

# every username (CSV + council) must exist on GitHub; 404s are listed and the run stops.
# Verified names are cached in users.ok so re-runs make no calls for them.
check_users() {
  local u out rc try bad=() n=0 kind
  touch "$OUT/users.ok"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    grep -qixF "$u" "$OUT/users.ok" && continue
    for try in 1 2 3; do
      out=$(gh api "users/$u" 2>&1 </dev/null); rc=$?
      if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qiE 'rate limit|HTTP 429'; then
        log "  rate limited, sleeping 60s (try $try/3)"; sleep 60; continue
      fi
      break
    done
    if [ $rc -eq 0 ]; then
      kind=$(printf '%s' "$out" | jq -r .type)
      if [ "$kind" = User ]; then printf '%s\n' "$u" >> "$OUT/users.ok"; else bad+=("$u (is an $kind, not a user)"); fi
    elif printf '%s' "$out" | grep -q 'HTTP 404'; then bad+=("$u")
    else die "could not check username $u: $(printf '%s' "$out" | head -c 160)"
    fi
    n=$((n+1)); sleep 0.2
  done < <( { cut -f2 "$OUT/members.tsv"; printf '%s\n' ${COUNCIL//,/ }; } | awk 'NF && !s[tolower($0)]++')
  if [ "${#bad[@]}" -gt 0 ]; then
    printf '%s\n' "${bad[@]}" > "$OUT/bad-usernames.txt"
    log "ERROR: ${#bad[@]} username(s) not found on GitHub (also in $OUT/bad-usernames.txt):"
    printf '   %s\n' "${bad[@]}" | tee -a "$LOG" >&2
    exit 1
  fi
  log "usernames ok ($n looked up, rest cached)"
}

# ---------- preflight ----------
preflight() {
  need gh; need jq; need python3; need base64
  gh auth status >/dev/null 2>&1 || die "gh not logged in: run  gh auth login"
  local scopes role
  scopes=$(gh api -i user 2>/dev/null </dev/null | grep -i '^x-oauth-scopes:' || true)
  if [ -n "$scopes" ] && ! printf '%s' "$scopes" | grep -q 'admin:org'; then
    die "token lacks admin:org (needed for settings + invites). Run: gh auth refresh -h github.com -s admin:org -s repo"
  fi
  get "orgs/$ORG" >/dev/null || die "org $ORG not found (or token can't see it)"
  role=$(get "user/memberships/orgs/$ORG" | jq -r '.role // empty')
  [ "$role" = "admin" ] || die "you are not an owner of $ORG (role: ${role:-none})"
  ME=$(get user | jq -r .login)
  load_csv
  if team_names | grep -qix "$COUNCIL_TEAM"; then die "team name $COUNCIL_TEAM is reserved"; fi
  # caches
  get --paginate "orgs/$ORG/teams" | jq -r '.[]|[.name,.slug,.id]|@tsv' > "$OUT/teams.cache"
  get --paginate "orgs/$ORG/invitations" | jq -r '.[]|select(.login!=null)|.login|ascii_downcase' > "$OUT/pending.cache"
  touch "$OUT/invites.tsv" "$OUT/repos.tsv"
}

# ---------- building blocks ----------
ensure_team() {  # $1 name -> prints "slug<TAB>id"
  local name=$1 hit res
  hit=$(awk -F'\t' -v n="$name" 'tolower($1)==tolower(n){print $2"\t"$3; exit}' "$OUT/teams.cache")
  if [ -n "$hit" ]; then log "  team exists: $name"; ev "$name" team exists; printf '%s' "$hit"; return 0; fi
  res=$(mut POST "orgs/$ORG/teams" "$(jq -nc --arg n "$name" '{name:$n,privacy:"secret",notification_setting:"notifications_disabled"}')") \
    || { log "  FAIL team $name: $(errmsg "$res")"; ev "$name" team failed "$(errmsg "$res")"; return 1; }
  hit=$(printf '%s' "$res" | jq -r '[.slug,.id]|@tsv')
  [ "$DRY" = 1 ] || printf '%s\t%s\n' "$name" "$hit" >> "$OUT/teams.cache"
  log "  team created: $name"; ev "$name" team created
  printf '%s' "$hit"
}

ensure_repo() {  # $1 repo
  local res
  if get "repos/$ORG/$1" >/dev/null; then log "  repo exists: $1"; REPO_STATE=exists; ev "$1" repo exists; return 0; fi
  res=$(mut POST "orgs/$ORG/repos" "$(jq -nc --arg n "$1" '{name:$n,description:"Bit N Build 2026 finals",private:true,has_issues:true,has_projects:false,has_wiki:false}')") \
    || { log "  FAIL repo $1: $(errmsg "$res")"; REPO_STATE=failed; ev "$1" repo failed "$(errmsg "$res")"; return 1; }
  REPO_STATE=created; [ "$DRY" = 1 ] && REPO_STATE=would-create
  log "  repo created: $1 (private)"; ev "$1" repo created
}

DEFAULT_README=$(cat <<'EOF'
# {{TEAM}} - Bit N Build 2026 Finals

This repo is private. Only your team and the organizers can see it.

Rules
- Push all your work here. Don't rewrite history (no force-push, no deleting branches). It gets checked.
- Don't commit secrets or .env files. Commit a .env.example instead.
- Don't change the repo visibility and don't add anyone outside your team.
- Anything unclear, ask the council.
EOF
)
GITIGNORE=$'.env\n.env.*\n!.env.example\nnode_modules/\n__pycache__/\n*.pyc\n.DS_Store\n'

put_file() {  # repo path content message
  local b64; b64=$(printf '%s' "$3" | base64 -w0)
  mut PUT "repos/$ORG/$1/contents/$2" "$(jq -nc --arg m "$4" --arg c "$b64" '{message:$m,content:$c}')"
}

seed_repo() {  # repo team -> prints baseline commit sha (empty if already seeded and unknown)
  local repo=$1 team=$2 readme res
  if get "repos/$ORG/$repo/contents/README.md" >/dev/null; then
    log "  already seeded"; ev "$repo" seed exists; awk -F'\t' -v r="$repo" '$4==r{print $6; exit}' "$OUT/repos.tsv"; return 0
  fi
  if [ -n "$README_FILE" ]; then readme=$(<"$README_FILE"); else readme=$DEFAULT_README; fi
  readme=${readme//'{{TEAM}}'/$team}
  res=$(put_file "$repo" README.md "$readme"$'\n' "Add README") || { log "  FAIL seed README: $(errmsg "$res")"; ev "$repo" seed failed "$(errmsg "$res")"; return 1; }
  res=$(put_file "$repo" .gitignore "$GITIGNORE" "Add .gitignore") || { log "  FAIL seed .gitignore: $(errmsg "$res")"; return 1; }
  log "  seeded README + .gitignore"; ev "$repo" seed created
  printf '%s' "$res" | jq -r '.commit.sha'
}

add_member() {  # team slug user [role]
  local team=$1 slug=$2 user=$3 role=${4:-member} res rc state detail="" new=0 ulc
  ulc=$(printf '%s' "$user" | tr 'A-Z' 'a-z')
  if awk -F'\t' -v t="$team" -v u="$ulc" 'tolower($2)==u && $1==t && $3=="active"{f=1} END{exit !f}' "$OUT/invites.tsv"; then
    INV_SKIP=$((INV_SKIP+1)); M_ACT=$((M_ACT+1)); ev "$team" "$user" skipped "already active"; return 0   # done in an earlier run
  fi
  if grep -qxF "$ulc" "$OUT/pending.cache" && awk -F'\t' -v t="$team" -v u="$ulc" 'tolower($2)==u && $1==t && $3=="pending"{f=1} END{exit !f}' "$OUT/invites.tsv"; then
    INV_SKIP=$((INV_SKIP+1)); M_PEND=$((M_PEND+1)); log "    $user already pending (not accepted yet)"; ev "$team" "$user" skipped "invite still pending"; return 0
  fi
  if [ "$INV_BLOCKED" = 1 ]; then M_WAIT=$((M_WAIT+1)); return 0; fi
  # not an org member yet => the PUT below sends an org invitation (counts toward the daily limit)
  get "orgs/$ORG/memberships/$user" >/dev/null || new=1
  if [ "$new" = 1 ] && ! grep -qxF "$ulc" "$OUT/pending.cache" && [ "$INVITE_CAP" -gt 0 ] && [ "$INV_SENT" -ge "$INVITE_CAP" ]; then
    [ "$INV_CAPPED" = 1 ] || log "    invite cap ($INVITE_CAP) reached, remaining new invites wait for the next run"
    INV_CAPPED=1; M_WAIT=$((M_WAIT+1)); return 0
  fi
  res=$(mut PUT "orgs/$ORG/teams/$slug/memberships/$user" "$(jq -nc --arg r "$role" '{role:$r}')"); rc=$?
  if [ $rc -eq 0 ]; then
    state=$(printf '%s' "$res" | jq -r '.state // "dry"'); INV_STREAK=0
    if [ "$state" = active ]; then M_ACT=$((M_ACT+1)); else M_PEND=$((M_PEND+1)); fi
    if [ "$new" = 1 ] && ! grep -qxF "$ulc" "$OUT/pending.cache"; then INV_SENT=$((INV_SENT+1)); fi
    log "    $user: $state$([ "$new" = 1 ] && echo ' (invited to org, not accepted yet)')"
  else
    state=failed; detail=$(errmsg "$res"); [ -n "$detail" ] || detail=$(printf '%s' "$res" | head -c 160 | tr '\n\t' '  ')
    INV_FAIL=$((INV_FAIL+1)); M_FAIL=$((M_FAIL+1)); INV_STREAK=$((INV_STREAK+1)); log "    FAIL $user: $detail"
  fi
  [ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\n' "$team" "$user" "$state" "$detail" >> "$OUT/invites.tsv"
  ev "$team" "$user" "$state" "$detail"
  if [ "$INV_STREAK" -ge 3 ]; then
    INV_BLOCKED=1; log "    3 failures in a row (daily invite limit?). Pausing member adds, re-run later."
  fi
  sleep 1
}

# ---------- commands ----------
cmd_check() {
  preflight; check_users
  : > "$OUT/plan.tsv"
  local t
  while IFS= read -r t; do
    printf '%s\t%s\t%s\n' "$t" "$(repo_of "$t")" "$(users_of "$t" | wc -l)" >> "$OUT/plan.tsv"
  done < <(team_names)
  log "org=$ORG  teams=$(wc -l < "$OUT/plan.tsv")  members=$(wc -l < "$OUT/members.tsv")  council=${COUNCIL:-none}($COUNCIL_PERM)"
  head -n 8 "$OUT/plan.tsv" | while IFS=$'\t' read -r a b c; do log "  $a -> $b ($c)"; done
  log "plan written to $OUT/plan.tsv"
}

has() { [[ " $STEPS " == *" $1 "* ]]; }
team_slug() { awk -F'\t' -v n="$1" 'tolower($1)==tolower(n){print $2"\t"$3; exit}' "$OUT/teams.cache"; }

team_result() {  # one RESULT line per team, from the per-team state kept by cmd_run
  local s="" v=ok
  has teams && s+=" team=${ts:-?}"; has repos && s+=" repo=${REPO_STATE:-?}"; has access && s+=" access=${acs:-?}"
  if has members; then
    if [ "$DRY" = 1 ]; then s+=" members=$(users_of "$t" | wc -l) to add"
    else s+=" members=$M_ACT active/$M_PEND pending/$M_FAIL failed$([ "$M_WAIT" -gt 0 ] && echo "/$M_WAIT not-attempted")"; fi
  fi
  if [ "${#FAILS[@]}" -gt "$bad" ]; then v=FAIL; elif [ "$M_PEND" -gt 0 ] || [ "$M_WAIT" -gt 0 ]; then v=wait; fi
  log "  RESULT $v  $t |$s"
}

cmd_run() {  # $1 = steps, any of: teams repos access members
  STEPS=$1
  preflight
  if has members || has council; then
    if ! awk -F'\t' '$2!=""{f=1} END{exit !f}' "$OUT/members.tsv"; then
      { has members && [ -z "$COUNCIL" ]; } && die "no GitHub usernames: set MEMBERS_CSV (form responses) or use a CSV with github_username"
      log "no participant usernames yet: adding the council only"
    fi
    check_users
  fi
  local total n=0 t repo r slug tid base cs="" cid u ts acs pre bad
  total=$(team_names | wc -l)
  log "== $STEPS  ORG=$ORG dry=$DRY teams=$total members=$(awk -F'\t' '$2!=""' "$OUT/members.tsv" | wc -l)"

  if has teams; then
    r=$(mut PATCH "orgs/$ORG" "$(jq -nc '{default_repository_permission:"none",members_can_create_repositories:false,members_can_fork_private_repositories:false}')") \
      && log "org settings: base permission none, no repo creation, no private forks" \
      || log "WARN org settings not applied: $(errmsg "$r")"
  fi

  if [ -n "$COUNCIL" ]; then
    if has teams; then r=$(ensure_team "$COUNCIL_TEAM") || die "could not create council team"; else r=$(team_slug "$COUNCIL_TEAM"); fi
    if [ -z "$r" ]; then [ "$DRY" = 1 ] && r=$'dry-run\t0' || die "council team missing: run './bnb26.sh teams' first"; fi
    IFS=$'\t' read -r cs cid <<<"$r"
    if has members || has council; then
      log "  council members:"
      for u in ${COUNCIL//,/ }; do add_member "$COUNCIL_TEAM" "$cs" "$u" maintainer; done
    fi
  fi

  while IFS= read -r t; do
    n=$((n+1)); repo=$(repo_of "$t"); ts=""; acs=""; REPO_STATE=""; M_ACT=0; M_PEND=0; M_FAIL=0; M_WAIT=0; bad=${#FAILS[@]}
    log "[$n/$total] $t -> $repo"
    if has teams; then
      pre=$(team_slug "$t")
      r=$(ensure_team "$t") || { FAILS+=("$t (team)"); ts=failed; team_result; continue; }
      if [ -n "$pre" ]; then ts=exists; elif [ "$DRY" = 1 ]; then ts=would-create; else ts=created; fi
    else
      r=$(team_slug "$t")
      if [ -z "$r" ]; then [ "$DRY" = 1 ] && r=$'dry-run\t0' || { log "  FAIL team missing: run './bnb26.sh teams' first"; FAILS+=("$t (team missing)"); ts=missing; team_result; continue; }; fi
    fi
    IFS=$'\t' read -r slug tid <<<"$r"
    if has repos; then
      ensure_repo "$repo" || { FAILS+=("$t (repo)"); team_result; continue; }
      base=$(seed_repo "$repo" "$t") || FAILS+=("$t (seed)")
      if [ "$DRY" != 1 ] && ! awk -F'\t' -v r="$repo" '$4==r{f=1} END{exit !f}' "$OUT/repos.tsv"; then
        printf '%s\t%s\t%s\t%s\thttps://github.com/%s/%s\t%s\n' "$t" "$slug" "$tid" "$repo" "$ORG" "$repo" "$base" >> "$OUT/repos.tsv"
      fi
    fi
    if has access; then
      r=$(mut PUT "orgs/$ORG/teams/$slug/repos/$ORG/$repo" '{"permission":"push"}') \
        || { log "  FAIL team access: $(errmsg "$r")"; ev "$t" access failed "$(errmsg "$r")"; FAILS+=("$t (access)"); acs=failed; team_result; continue; }
      acs=push; ev "$t" access ok "team push"
      if [ -n "$cs" ]; then
        r=$(mut PUT "orgs/$ORG/teams/$cs/repos/$ORG/$repo" "$(jq -nc --arg p "$COUNCIL_PERM" '{permission:$p}')") \
          && ev "$t" access ok "council $COUNCIL_PERM" \
          || { log "  FAIL council access: $(errmsg "$r")"; ev "$t" access failed "council: $(errmsg "$r")"; FAILS+=("$t (council)"); acs="push,council-failed"; }
      fi
    fi
    if has members; then
      while IFS= read -r u; do add_member "$t" "$slug" "$u"; done < <(users_of "$t")
    fi
    team_result
    [ "$DRY" = 1 ] || sleep "$SLEEP"
  done < <([ "$STEPS" = council ] || team_names)

  log "== done ($STEPS). teams=$total failed=${#FAILS[@]}$(has members && echo " | new org invites=$INV_SENT skipped=$INV_SKIP failed=$INV_FAIL")"
  if [ "${#FAILS[@]}" -gt 0 ]; then log "failed steps:"; printf '   %s\n' "${FAILS[@]}" | tee -a "$LOG" >&2; fi
  if [ "$INV_BLOCKED" = 1 ] || [ "$INV_CAPPED" = 1 ]; then log "member adds paused or capped: re-run './bnb26.sh members' later, finished members are skipped"; fi
  log "files: $OUT/events.tsv (what happened, with times)  $OUT/invites.tsv  $OUT/repos.tsv  log: $LOG"
  has members && log "who has accepted: ./bnb26.sh status"
  [ "${#FAILS[@]}" -eq 0 ]
}

chk_member() {  # team slug user: bump act/pend/miss (cmd_status locals) and list not-accepted people in $na
  local t=$1 slug=$2 u=$3 ul st ts days=-
  ul=$(printf '%s' "$u" | tr 'A-Z' 'a-z')
  st=$(get "orgs/$ORG/teams/$slug/memberships/$u" | jq -r '.state // "missing"')
  case "$st" in
    active) act=$((act+1));;
    pending)
      pend=$((pend+1)); ts=$(awk -F'\t' -v u="$ul" '$1==u{print $2; exit}' "$OUT/inv.cache")
      [ -z "$ts" ] || days=$(( (now - $(date -d "$ts" +%s)) / 86400 ))
      printf '%s\t%s\tpending\t%s\n' "$t" "$u" "$days" >> "$na";;
    *)
      miss=$((miss+1)); st=missing; grep -qxF "$ul" "$OUT/expired.cache" && st=expired
      printf '%s\t%s\t%s\t-\n' "$t" "$u" "$st" >> "$na";;
  esac
}

cmd_status() {  # live view: what exists on GitHub right now and who has accepted
  STEPS=status; preflight
  local t repo slug rj rt pt pc u act pend miss prob word col nu now f="$OUT/status-$STAMP.tsv" na="$OUT/not-accepted.tsv"
  local T_ok=0 T_wait=0 T_bad=0 T_a=0 T_p=0 T_m=0
  get --paginate "orgs/$ORG/invitations" | jq -r '.[]|select(.login!=null)|[(.login|ascii_downcase),.created_at]|@tsv' > "$OUT/inv.cache"
  get --paginate "orgs/$ORG/failed_invitations" | jq -r '.[]|select(.login!=null)|.login|ascii_downcase' > "$OUT/expired.cache"
  printf 'team\trepo\tstate\tproblem\tactive\tpending\tmissing\n' > "$f"
  printf 'team\tuser\tstate\tdays_waiting\n' > "$na"
  now=$(date +%s)
  log "== status $ORG   (ALL-IN = everyone accepted, WAITING = invites not accepted yet, READY = team+repo+access done, no members yet)"
  if [ -n "$COUNCIL" ]; then   # council row first
    slug=$(team_slug "$COUNCIL_TEAM" | cut -f1); act=0; pend=0; miss=0; nu=0; t=$COUNCIL_TEAM
    if [ -n "$slug" ]; then for u in ${COUNCIL//,/ }; do nu=$((nu+1)); chk_member "$t" "$slug" "$u"; done; fi
    if [ -z "$slug" ] || [ "$miss" -gt 0 ]; then word=ACTION col=31; T_bad=$((T_bad+1)); elif [ "$pend" -gt 0 ]; then word=WAITING col=33; T_wait=$((T_wait+1)); else word=ALL-IN col=32; T_ok=$((T_ok+1)); fi
    T_a=$((T_a+act)); T_p=$((T_p+pend)); T_m=$((T_m+miss))
    printf '%s %-28s %s\n' "$(paint "$col" "$(printf '%-8s' "$word")")" "$t (council)" "$act active, $pend pending, $miss missing" | tee -a "$LOG"
  fi
  while IFS= read -r t; do
    repo=$(repo_of "$t"); prob=""; act=0; pend=0; miss=0; nu=0
    slug=$(team_slug "$t" | cut -f1)
    [ -n "$slug" ] || prob="no team"
    if rj=$(get "repos/$ORG/$repo"); then
      if [ -n "$slug" ]; then
        rt=$(get "repos/$ORG/$repo/teams")
        pt=$(jq -r --arg s "$slug" '.[]|select(.slug==$s)|.permission' <<<"$rt")
        [ "$pt" = push ] || prob="${prob:+$prob, }team access '${pt:-none}'"
        if [ -n "$COUNCIL" ]; then
          pc=$(jq -r --arg s "$(team_slug "$COUNCIL_TEAM" | cut -f1)" '.[]|select(.slug==$s)|.permission' <<<"$rt")
          [ "$pc" = "$COUNCIL_PERM" ] || prob="${prob:+$prob, }council access '${pc:-none}'"
        fi
      fi
    else prob="${prob:+$prob, }no repo"; fi
    if [ -n "$slug" ]; then
      while IFS= read -r u; do nu=$((nu+1)); chk_member "$t" "$slug" "$u"; done < <(users_of "$t")
    fi
    T_a=$((T_a+act)); T_p=$((T_p+pend)); T_m=$((T_m+miss))
    if [ -n "$prob" ]; then word=PROBLEM col=31; T_bad=$((T_bad+1))
    elif [ "$miss" -gt 0 ]; then word=ACTION col=31; T_bad=$((T_bad+1))
    elif [ "$pend" -gt 0 ]; then word=WAITING col=33; T_wait=$((T_wait+1))
    elif [ "$nu" -eq 0 ]; then word=READY col=36; T_ok=$((T_ok+1))
    else word=ALL-IN col=32; T_ok=$((T_ok+1)); fi
    printf '%s %-28s %s\n' "$(paint "$col" "$(printf '%-8s' "$word")")" "$t" \
      "$([ "$nu" -gt 0 ] && echo "$act active, $pend pending, $miss missing")${prob:+  [$prob]}" | tee -a "$LOG"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$repo" "$word" "$prob" "$act" "$pend" "$miss" >> "$f"
  done < <(team_names)
  log "== summary: ready/all-in=$T_ok  waiting=$T_wait  need action=$T_bad | members active=$T_a pending=$T_p missing/expired=$T_m"
  if [ "$(wc -l < "$na")" -gt 1 ]; then
    log "not accepted / not added yet (full list: $na):"
    awk -F'\t' 'NR>1{g[$1]=g[$1] (g[$1]?", ":"") $2 " (" $3 (($4!="-")?" " $4 "d":"") ")"} END{for(t in g) print "  " t ": " g[t]}' "$na" | sort | tee -a "$LOG"
    log "expired invites: re-run './bnb26.sh members' to send them again"
  fi
  log "table: $f"
  [ "$T_bad" -eq 0 ]
}

PASS=0; BAD=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); log "  PASS $1"; else BAD=$((BAD+1)); log "  FAIL $1 (got '$2', want '$3')"; fi; }

cmd_audit() {
  preflight
  local o t repo slug rj rt nt pt pc direct u st act pend miss extra f="$OUT/audit-$STAMP.tsv" exp
  local TA=0 TP=0 TM=0
  o=$(get "orgs/$ORG")
  log "== audit $ORG"
  chk "org base permission" "$(jq -r .default_repository_permission <<<"$o")" none
  chk "members can't create repos" "$(jq -r .members_can_create_repositories <<<"$o")" false
  chk "members can't fork private repos" "$(jq -r .members_can_fork_private_repositories <<<"$o")" false
  exp=1; [ -n "$COUNCIL" ] && exp=2
  printf 'team\trepo\tprivate\tteam_perm\tcouncil_perm\tteams_on_repo\tdirect_collabs\tactive\tpending\tmissing\textra\n' > "$f"
  if [ -n "$COUNCIL" ]; then
    local cs; cs=$(awk -F'\t' -v n="$COUNCIL_TEAM" 'tolower($1)==tolower(n){print $2; exit}' "$OUT/teams.cache")
    act=0; pend=0; miss=0
    for u in ${COUNCIL//,/ }; do
      st=$(get "orgs/$ORG/teams/${cs:-none}/memberships/$u" | jq -r '.state // "missing"')
      case "$st" in active) act=$((act+1));; pending) pend=$((pend+1));; *) miss=$((miss+1)); log "  FAIL council $u: missing";; esac
    done
    BAD=$((BAD+miss)); log "  council: active=$act pending=$pend missing=$miss"
  fi
  while IFS= read -r t; do
    repo=$(repo_of "$t")
    slug=$(awk -F'\t' -v n="$t" 'tolower($1)==tolower(n){print $2; exit}' "$OUT/teams.cache")
    if [ -z "$slug" ]; then BAD=$((BAD+1)); log "  FAIL $t: team missing"; continue; fi
    if ! rj=$(get "repos/$ORG/$repo"); then BAD=$((BAD+1)); log "  FAIL $t: repo $repo missing"; continue; fi
    rt=$(get "repos/$ORG/$repo/teams")
    nt=$(jq 'length' <<<"$rt")
    pt=$(jq -r --arg s "$slug" '.[]|select(.slug==$s)|.permission' <<<"$rt")
    pc=$(jq -r --arg s "$(awk -F'\t' -v n="$COUNCIL_TEAM" 'tolower($1)==tolower(n){print $2; exit}' "$OUT/teams.cache")" '.[]|select(.slug==$s)|.permission' <<<"$rt")
    direct=$(get "repos/$ORG/$repo/collaborators?affiliation=direct&per_page=100" | jq 'length')
    act=0; pend=0; miss=0
    while IFS= read -r u; do
      st=$(get "orgs/$ORG/teams/$slug/memberships/$u" | jq -r '.state // "missing"')
      case "$st" in active) act=$((act+1));; pending) pend=$((pend+1));; *) miss=$((miss+1)); log "  FAIL $t: $u missing";; esac
    done < <(users_of "$t")
    # active team members that are not in the CSV (you, the team creator, are expected)
    extra=$(get --paginate "orgs/$ORG/teams/$slug/members" | jq -r '.[].login|ascii_downcase' \
      | grep -vixF -f <(users_of "$t"; echo "$ME") | paste -sd, - || true)
    TA=$((TA+act)); TP=$((TP+pend)); TM=$((TM+miss)); BAD=$((BAD+miss))
    [ -z "$extra" ] || log "  WARN $t: team has members not in the CSV: $extra"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$repo" "$(jq -r .private <<<"$rj")" "$pt" "${pc:--}" "$nt" "$direct" "$act" "$pend" "$miss" "${extra:--}" >> "$f"
    [ "$(jq -r .private <<<"$rj")" = true ] || { BAD=$((BAD+1)); log "  FAIL $repo is PUBLIC"; }
    [ "$pt" = push ] || { BAD=$((BAD+1)); log "  FAIL $repo team permission '$pt' (want push)"; }
    [ "$nt" = "$exp" ] || { BAD=$((BAD+1)); log "  FAIL $repo has $nt teams (want $exp)"; }
    if [ -n "$COUNCIL" ] && [ "$pc" != "$COUNCIL_PERM" ]; then BAD=$((BAD+1)); log "  FAIL $repo council permission '${pc:-none}'"; fi
    [ "$direct" = 0 ] || log "  WARN $repo has $direct direct collaborator(s)"
  done < <(team_names)
  log "teams checked: $(team_names | wc -l)  members: active=$TA pending=$TP missing=$TM  org-level pending invites: $(wc -l < "$OUT/pending.cache")  FAIL count: $BAD"
  log "table: $f"
  column -t -s $'\t' "$f" 2>/dev/null || cat "$f"
  [ "$BAD" -eq 0 ]
}

cmd_monitor() {
  preflight
  local f="$OUT/monitor-$STAMP.tsv" t repo base rj br cj st ahead last pushed priv flag
  printf 'team\trepo\tprivate\tstatus\tahead_by\tlast_commit\tpushed_at\tflag\n' > "$f"
  while IFS= read -r t; do
    repo=$(repo_of "$t")
    base=$(awk -F'\t' -v r="$repo" '$4==r{print $6; exit}' "$OUT/repos.tsv")
    if ! rj=$(get "repos/$ORG/$repo"); then printf '%s\t%s\t-\t-\t-\t-\t-\tREPO MISSING\n' "$t" "$repo" >> "$f"; continue; fi
    br=$(jq -r .default_branch <<<"$rj"); priv=$(jq -r .private <<<"$rj"); pushed=$(jq -r .pushed_at <<<"$rj")
    flag=""; st="no-baseline"; ahead="-"; last="-"
    [ "$priv" = true ] || flag="PUBLIC"
    if [ -n "$base" ] && cj=$(get "repos/$ORG/$repo/compare/${base}...${br}"); then
      st=$(jq -r .status <<<"$cj"); ahead=$(jq -r .ahead_by <<<"$cj")
      last=$(jq -r '.commits[-1].commit.committer.date // "-"' <<<"$cj")
      case "$st" in diverged|behind) flag="$flag HISTORY REWRITTEN";; esac
    elif [ -n "$base" ]; then st="baseline-gone"; flag="$flag HISTORY REWRITTEN"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$repo" "$priv" "$st" "$ahead" "$last" "$pushed" "${flag# }" >> "$f"
  done < <(team_names)
  column -t -s $'\t' "$f" 2>/dev/null || cat "$f"
  log "flagged: $(awk -F'\t' 'NR>1 && $8!=""' "$f" | wc -l)   file: $f"
}

cmd_cleanup() {
  case "$(printf '%s' "$ORG" | tr 'A-Z' 'a-z')" in *test*) ;; *) die "cleanup only runs on orgs with 'test' in the name (ORG=$ORG)";; esac
  need gh; need jq
  read -r -p "Delete ALL repos, teams and pending invites in $ORG? Type the org name to confirm: " ans
  [ "$ans" = "$ORG" ] || die "aborted"
  local x
  for x in $(get --paginate "orgs/$ORG/repos" | jq -r '.[].name'); do mut DELETE "repos/$ORG/$x" >/dev/null && log "deleted repo $x" || log "FAIL repo $x (need: gh auth refresh -s delete_repo)"; done
  for x in $(get --paginate "orgs/$ORG/teams" | jq -r '.[].slug'); do mut DELETE "orgs/$ORG/teams/$x" >/dev/null && log "deleted team $x"; done
  for x in $(get --paginate "orgs/$ORG/invitations" | jq -r '.[].id'); do mut DELETE "orgs/$ORG/invitations/$x" >/dev/null && log "cancelled invite $x"; done
  rm -f "$OUT/repos.tsv" "$OUT/invites.tsv"
  log "cleanup done"
}

case "$CMD" in
  check)   cmd_check ;;
  teams)   cmd_run "teams" ;;
  repos)   cmd_run "repos" ;;
  access)  cmd_run "access" ;;
  members) cmd_run "members" ;;
  council) cmd_run "council" ;;
  setup)   cmd_run "teams repos access members" ;;
  status)  cmd_status ;;
  audit)   cmd_audit ;;
  monitor) cmd_monitor ;;
  cleanup) cmd_cleanup ;;
  *) sed -n '2,33p' "$0" ;;
esac
