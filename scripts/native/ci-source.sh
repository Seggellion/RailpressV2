# Shared trusted-source boundary for the GitHub native CI entry points.
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REPOSITORY:-}" == Seggellion/RailpressV2 &&
   "${GITHUB_REF:-}" == refs/heads/main && "${GITHUB_EVENT_NAME:-}" =~ ^(push|workflow_dispatch)$ &&
   "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ && "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || {
  echo 'Native qualification requires an exact, trusted main checkout' >&2
  exit 1
}
git diff --quiet && git diff --cached --quiet || {
  echo 'Native qualification requires an unchanged tracked checkout' >&2
  exit 1
}
