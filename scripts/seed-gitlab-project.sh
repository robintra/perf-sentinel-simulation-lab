#!/usr/bin/env bash
# Bootstrap the perf-sentinel-template-test project on the in-cluster
# GitLab CE. Idempotent: if the project already exists, exit clean.
# The script writes /tmp/gitlab-pat.txt for the verify step.
# Usage: ./scripts/seed-gitlab-project.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

NAMESPACE="gitlab-ce"
RELEASE_NAME="gitlab"
GITLAB_URL="http://localhost:8181"
PROJECT_NAME="perf-sentinel-template-test"
ROOT_USER="root"
PAT_FILE="/tmp/gitlab-pat.txt"
PROJECT_FILE="/tmp/gitlab-project.json"
FIXTURES_DIR="${REPO_ROOT}/artifacts/fixtures"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

for f in "${FIXTURES_DIR}/perf-sentinel-test.toml" \
         "${FIXTURES_DIR}/gitlab-ci-from-upstream.yml" \
         "${FIXTURES_DIR}/em-real-time-traces.json"; do
  [ -f "${f}" ] || die "missing fixture: ${f}"
done

step "Checking GitLab API reachability at ${GITLAB_URL}"
curl -fsS "${GITLAB_URL}/-/readiness" >/dev/null \
  || die "GitLab API not reachable. Run make up-gitlab first."

step "Reading initial root password from Secret"
ROOT_PASSWORD="$(kubectl -n "${NAMESPACE}" get secret \
  gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d)"
[ -n "${ROOT_PASSWORD}" ] || die "empty root password from Secret"

step "Acquiring an OAuth2 access token (root login)"
OAUTH_RESPONSE="$(curl -fsS -X POST "${GITLAB_URL}/oauth/token" \
  -H "Content-Type: application/json" \
  -d "$(printf '{"grant_type":"password","username":"%s","password":"%s"}' \
        "${ROOT_USER}" "${ROOT_PASSWORD}")")"
OAUTH_TOKEN="$(printf '%s' "${OAUTH_RESPONSE}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')"
[ -n "${OAUTH_TOKEN}" ] || die "failed to obtain OAuth2 access token"

step "Creating a Personal Access Token for git operations"
# OAuth2 password-grant tokens are not accepted by GitLab's git HTTP
# transport (returns "Nil JSON web token"). PATs work for both API
# calls and git push/pull, so we mint one and use it everywhere.
PAT_RESPONSE="$(curl -fsS -X POST "${GITLAB_URL}/api/v4/users/1/personal_access_tokens" \
  -H "Authorization: Bearer ${OAUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(printf '{"name":"%s","scopes":["api","write_repository","read_repository"]}' \
        "lab-seed-$(date -u +%Y%m%dT%H%M%SZ)")")"
TOKEN="$(printf '%s' "${PAT_RESPONSE}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
[ -n "${TOKEN}" ] || die "failed to mint Personal Access Token"
printf '%s' "${TOKEN}" > "${PAT_FILE}"
chmod 600 "${PAT_FILE}"
ok "PAT saved to ${PAT_FILE}"

step "Looking up or creating project ${PROJECT_NAME}"
EXISTING="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  "${GITLAB_URL}/api/v4/projects?owned=true&search=${PROJECT_NAME}" \
  | python3 -c 'import json,sys
projects=json.load(sys.stdin)
match=[p for p in projects if p["path"]==sys.argv[1]]
print(match[0]["id"] if match else "")' "${PROJECT_NAME}")"

if [ -n "${EXISTING}" ]; then
  ok "project exists with id ${EXISTING}, skipping creation"
  PROJECT_ID="${EXISTING}"
  printf '{"id":%s,"path":"%s"}' "${PROJECT_ID}" "${PROJECT_NAME}" > "${PROJECT_FILE}"
else
  curl -fsS -X POST "${GITLAB_URL}/api/v4/projects" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"name":"%s","path":"%s","initialize_with_readme":true,"visibility":"public"}' \
          "${PROJECT_NAME}" "${PROJECT_NAME}")" \
    > "${PROJECT_FILE}"
  PROJECT_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "${PROJECT_FILE}")"
  ok "project ${PROJECT_NAME} created with id ${PROJECT_ID}"
fi

step "Cloning project and populating it with fixtures"
WORK_DIR="$(mktemp -d)"
ASKPASS_SCRIPT="$(mktemp)"
# Trap removes both the work dir and the askpass shim. The token never
# lands in argv: git reads it from the env-only LAB_GIT_TOKEN var via
# the askpass script, instead of the historical
# `http://oauth2:${TOKEN}@localhost/...` URL pattern.
trap 'rm -rf "${WORK_DIR}"; rm -f "${ASKPASS_SCRIPT}"' EXIT
cat > "${ASKPASS_SCRIPT}" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  Username*) echo oauth2 ;;
  Password*) echo "${LAB_GIT_TOKEN}" ;;
esac
ASKPASS
chmod 700 "${ASKPASS_SCRIPT}"
export LAB_GIT_TOKEN="${TOKEN}"
export GIT_ASKPASS="${ASKPASS_SCRIPT}"
# After a fresh project create, GitLab finalizes the repo via Sidekiq
# (initial commit, default branch). Until that finishes, git Basic
# auth can return 401/403 even though the API and the token are fine.
# Retry the clone for up to 60 s, and on the final attempt surface
# the real stderr so a definitive failure (revoked token, deleted
# project, DNS down) is not buried under the Sidekiq race assumption.
CLONE_ERR="$(mktemp)"
for attempt in $(seq 1 30); do
  if git clone -q "${GITLAB_URL}/${ROOT_USER}/${PROJECT_NAME}.git" "${WORK_DIR}" 2>"${CLONE_ERR}"; then
    rm -f "${CLONE_ERR}"
    break
  fi
  if [ "${attempt}" -eq 30 ]; then
    color_red "    git clone stderr:"
    sed 's/^/      /' "${CLONE_ERR}" >&2
    rm -f "${CLONE_ERR}"
    die "git clone never succeeded after 60 s"
  fi
  rm -rf "${WORK_DIR}"
  WORK_DIR="$(mktemp -d)"
  sleep 2
done
pushd "${WORK_DIR}" >/dev/null

cp "${FIXTURES_DIR}/em-real-time-traces.json" test-traces.json
cp "${FIXTURES_DIR}/perf-sentinel-test.toml"  .perf-sentinel.toml
cp "${FIXTURES_DIR}/gitlab-ci-from-upstream.yml" .gitlab-ci.yml

git config user.email "lab@example.com"
git config user.name "lab-seed"
git add .
if git diff --cached --quiet; then
  ok "no changes to push, project already seeded"
else
  git commit -q -m "Seed: template + fixture + config"
  git push -q origin HEAD:main
  ok "initial commit pushed to main"
fi
unset LAB_GIT_TOKEN GIT_ASKPASS
popd >/dev/null

color_green ""
color_green "Project ready at ${GITLAB_URL}/${ROOT_USER}/${PROJECT_NAME}"
color_green "Root login: ${ROOT_USER} / kubectl get secret ... (see make up-gitlab output)"
color_green "Token saved to ${PAT_FILE}"
