# Shared trusted-source boundary for the GitHub native CI entry points.
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REPOSITORY:-}" == Seggellion/RailpressV2 &&
   "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ && "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || {
  echo 'Native qualification requires an exact checkout from the trusted repository' >&2
  exit 1
}
if [[ "${GITHUB_REF:-}" == refs/heads/main ]]; then
  [[ "${GITHUB_EVENT_NAME:-}" =~ ^(push|workflow_dispatch)$ ]] || {
    echo 'Native qualification on main requires a push or manual dispatch' >&2
    exit 1
  }
else
  [[ "${GITHUB_REF:-}" == refs/heads/codex/source-alpha-modularity-review &&
     "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
     "${GITHUB_ACTOR:-}" == "${GITHUB_REPOSITORY%%/*}" &&
     "${GITHUB_TRIGGERING_ACTOR:-}" == "${GITHUB_REPOSITORY%%/*}" &&
     "${GITHUB_WORKFLOW_REF:-}" == "$GITHUB_REPOSITORY/.github/workflows/native-qualification.yml@$GITHUB_REF" &&
     "${GITHUB_WORKFLOW_SHA:-}" == "$GITHUB_SHA" &&
     "${RAILPRESS_CI_REVIEW_SHA:-}" == "$GITHUB_SHA" ]] || {
    echo 'Source review requires an owner dispatch bound to the reviewed branch and exact commit' >&2
    exit 1
  }
fi
git diff --quiet && git diff --cached --quiet || {
  echo 'Native qualification requires an unchanged tracked checkout' >&2
  exit 1
}
