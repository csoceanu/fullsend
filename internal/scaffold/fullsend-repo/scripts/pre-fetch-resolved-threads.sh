#!/usr/bin/env bash
# pre-fetch-resolved-threads.sh — Fetch human-resolved review threads before the review agent runs
#
# Queries the PR's review threads through the fullsend forge client and writes
# a JSON file listing threads that a human explicitly resolved. The
# review agent uses this to avoid re-raising findings that a person
# already dismissed.
#
# Threads resolved by the bot itself (auto-resolution of outdated
# comments) are excluded — only human resolutions count.
#
# If a thread's inline comment contains a finding id marker
# (<!-- finding:f_abc -->), the id is included in the output so the
# agent can match by exact id instead of fuzzy file+line.
#
# Best-effort: if the GraphQL query fails or any step errors, the
# script writes an empty file and exits 0 so the review proceeds
# without resolution data (current behavior preserved).
#
# Required environment variables (set by the review agent):
#
#   - GH_TOKEN          — token with read access to the PR
#   - SOURCE_REPO       — owner/repo (e.g., "fullsend-ai/fullsend")
#   - PR_NUM            — PR number
#   - ORG_NAME          — org name for bot identity filtering
#   - FULLSEND_BIN      — optional path to the fullsend CLI (defaults to fullsend)
#
# Outputs (via GITHUB_OUTPUT):
#   - human_resolved_file — path to the JSON file
set -euo pipefail

OUTPUT_FILE="${GITHUB_WORKSPACE:-/tmp}/human-resolved-threads.json"

# This helper is intended for the review-agent pre-script. Local invocations
# and non-GitHub runners must not attempt a GitHub review-thread lookup.
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  printf '%s\n' '{"resolved_threads":[],"metadata":{"skipped":"not_github_actions"}}' > "${OUTPUT_FILE}"
  echo "human_resolved_file=${OUTPUT_FILE}" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

REVIEW_BOT="${ORG_NAME}-review[bot]"
SHARED_REVIEW_BOT="fullsend-ai-review[bot]"
REVIEW_BOT_LOGIN="${ORG_NAME}-review"
SHARED_REVIEW_BOT_LOGIN="fullsend-ai-review"

FULLSEND_BIN="${FULLSEND_BIN:-fullsend}"
if ! response=$("${FULLSEND_BIN}" fetch-review-threads --repo "${SOURCE_REPO}" --pr "${PR_NUM}" 2>/dev/null); then
  echo "::warning::Failed to fetch review threads through forge client — writing empty resolved-threads file"
  echo '{"resolved_threads":[],"metadata":{"error":"forge_fetch_failed"}}' > "${OUTPUT_FILE}"
  echo "human_resolved_file=${OUTPUT_FILE}" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

nodes_json=$(echo "${response}" | jq -c '.threads // []' 2>/dev/null) || {
  echo "::warning::Failed to parse review threads — writing empty resolved-threads file"
  echo '{"resolved_threads":[],"metadata":{"error":"parse_failed"}}' > "${OUTPUT_FILE}"
  echo "human_resolved_file=${OUTPUT_FILE}" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
}
truncated=$(echo "${response}" | jq -r '.truncated // false' 2>/dev/null) || truncated="false"

# --- Filter and transform ---
# Select threads that:
#   - are resolved
#   - were resolved by a human (not the review bot)
#   - have at least one comment
#   - comment pagination is complete (incomplete pages might hide context)
#
# For each matching thread, extract:
#   - file, line, original_line from the thread
#   - resolved_by from resolvedBy.login
#   - the first bot comment body (for snippet matching)
#   - the resolver's last comment (the resolution rationale) — only
#     comments from the resolvedBy user count, not any human
#   - finding_id if present in the bot comment (<!-- finding:f_xxx -->)
#   - resolution_context classification: explicit_dismissal when the
#     resolver left a comment, silent_resolution otherwise
#
# The forge client normalizes the GraphQL actor type into author_type. Bots
# are author_type "Bot" on comments, while resolvedBy is filtered by the
# GitHub App login suffix.

RESOLVED_THREADS=$(echo "${nodes_json}" | jq -c \
  --arg bot "${REVIEW_BOT}" \
  --arg shared_bot "${SHARED_REVIEW_BOT}" \
  --arg bot_login "${REVIEW_BOT_LOGIN}" \
  --arg shared_bot_login "${SHARED_REVIEW_BOT_LOGIN}" \
  '[.[]
    | select(.is_resolved == true)
    | select(.resolved_by != null and .resolved_by != "")
    | select(.resolved_by != $bot and .resolved_by != $shared_bot)
    | select((.resolved_by | endswith("[bot]")) | not)
    | select((.comments // [] | length) > 0)
    | select((.comments_truncated // false) == false)
    | .resolved_by as $resolver
    | {
        file: .path,
        line: .line,
        original_line: .original_line,
        resolved_by: $resolver,
        bot_finding_snippet: (
          [.comments[]
           | select(.author_type == "Bot")
           | select(.author == $bot_login or .author == $shared_bot_login or
                    .author == $bot or .author == $shared_bot)]
          | first // null
          | if . then (.body | .[0:200]) else null end
        ),
        finding_id: (
          [.comments[]
           | select(.author_type == "Bot")
           | select(.author == $bot_login or .author == $shared_bot_login or
                    .author == $bot or .author == $shared_bot)]
          | first // null
          | if . then (.body | capture("<!-- finding:(?<id>[a-zA-Z0-9_]+) -->") // null | .id // null) else null end
        ),
        human_response: (
          [.comments[] | select(.author == $resolver)]
          | last // null
          | if . then (.body | .[0:500]) else null end
        ),
        resolution_context: (
          if ([.comments[] | select(.author == $resolver)] | length) > 0
          then "explicit_dismissal"
          else "silent_resolution"
          end
        )
      }
  ]' 2>/dev/null) || RESOLVED_THREADS="[]"

THREAD_COUNT=$(echo "${nodes_json}" | jq 'length' 2>/dev/null) || THREAD_COUNT=0
RESOLVED_COUNT=$(echo "${RESOLVED_THREADS}" | jq 'length' 2>/dev/null) || RESOLVED_COUNT=0

# --- Write output ---
if ! jq -n \
  --argjson threads "${RESOLVED_THREADS}" \
  --argjson pr_num "${PR_NUM}" \
  --arg repo "${SOURCE_REPO}" \
  --argjson thread_count "${THREAD_COUNT}" \
  --argjson resolved_count "${RESOLVED_COUNT}" \
  --argjson truncated "${truncated}" \
  --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    resolved_threads: $threads,
    metadata: {
      pr_number: $pr_num,
      repo: $repo,
      thread_count: $thread_count,
      human_resolved_count: $resolved_count,
      truncated: $truncated,
      fetched_at: $fetched_at
    }
  }' > "${OUTPUT_FILE}"; then
  echo "::warning::Failed to write resolved-threads file — writing empty resolved-threads file"
  echo '{"resolved_threads":[],"metadata":{"error":"write_failed"}}' > "${OUTPUT_FILE}"
fi

echo "Resolved threads: ${RESOLVED_COUNT} human-resolved out of ${THREAD_COUNT} total"
echo "human_resolved_file=${OUTPUT_FILE}" >> "${GITHUB_OUTPUT:-/dev/null}"
