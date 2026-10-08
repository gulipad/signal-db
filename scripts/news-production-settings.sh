#!/usr/bin/env bash
# Apply Exponential News' Supabase settings to the production project.
#
# These settings live in the Supabase project, not in migrations, and are
# shared with Signal. The script changes only what News needs and leaves
# everything else (GitHub login, Site URL, ...) as it is:
#
#   Data API  add `news` to the exposed schemas
#   Auth      email provider on, "Confirm email" on (required: News gives
#             Exponential badges by confirmed email), minimum password length
#             of at least 8, News' email templates (supabase/templates)
#   Auth      links in auth emails last an hour (what the emails say)
#   Auth      with NEWS_URL: <NEWS_URL>auth/confirm** added to the redirect URLs
#   Auth      with NEWS_URL and SEND_EMAIL_HOOK_SECRET_FILE: the Send Email
#             Hook, so every auth email is sent by News through Resend
#             (<NEWS_URL>api/auth/send-email). Turn it on only once News is
#             deployed with RESEND_API_KEY and the same secret: from then on,
#             no auth email leaves without it.
#
# Usage, from your own terminal (not through an AI tool, so the token stays
# with you):
#
#   export SUPABASE_ACCESS_TOKEN=...   # https://supabase.com/dashboard/account/tokens
#   export NEWS_URL=https://exponential-news.vercel.app/              # optional
#   export SEND_EMAIL_HOOK_SECRET_FILE=~/.config/exponential-news/send-email-hook-secret  # optional
#   scripts/news-production-settings.sh            # shows the changes, asks first
#   scripts/news-production-settings.sh --yes      # no question
set -euo pipefail

REF=${REF:-fgvloiinjfnpwiitnkiz}
API="https://api.supabase.com/v1/projects/$REF"
TEMPLATES="$(cd "$(dirname "$0")/../supabase/templates" && pwd)"
YES=${1:-}

: "${SUPABASE_ACCESS_TOKEN:?Set SUPABASE_ACCESS_TOKEN (https://supabase.com/dashboard/account/tokens)}"

api() {  # api METHOD PATH [JSON]
  local args=(-sS -f -X "$1" "$API$2" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN")
  if [ $# -ge 3 ]; then args+=(-H "Content-Type: application/json" --data-binary "$3"); fi
  curl "${args[@]}"
}

# --- Data API ---------------------------------------------------------------

postgrest=$(api GET /postgrest)
schemas=$(jq -r '.db_schema' <<<"$postgrest")
if grep -qE '(^|,)[[:space:]]*news[[:space:]]*(,|$)' <<<"$schemas"; then
  postgrest_patch='{}'
else
  # Exposing a schema that doesn't exist stops the whole Data API (Signal's
  # too) from loading its schema cache. Push the migrations first.
  exists=$(api POST /database/query '{"query": "select exists (select 1 from pg_namespace where nspname = '\''news'\'') as ok"}' \
           | jq -r '.[0].ok')
  if [ "$exists" != "true" ]; then
    echo "The news schema doesn't exist in $REF yet: run 'supabase db push' first." >&2
    exit 1
  fi
  postgrest_patch=$(jq -nc --arg s "$schemas, news" '{db_schema: $s}')
fi

# --- Auth -------------------------------------------------------------------

auth=$(api GET /config/auth)
template() { cat "$TEMPLATES/$1.html"; }

auth_patch=$(jq -nc \
  --argjson cur "$auth" \
  --arg news_url "${NEWS_URL:-}" \
  --arg confirmation "$(template confirmation)" \
  --arg magic_link "$(template magic_link)" \
  --arg recovery "$(template recovery)" \
  --arg email_change "$(template email_change)" \
  '
  ($cur.uri_allow_list // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $urls
  | ($news_url | if . == "" then null else (sub("/?$"; "/") + "auth/confirm**") end) as $confirm
  | {
      external_email_enabled: true,
      mailer_autoconfirm: false,
      mailer_otp_exp: 3600,
      password_min_length: ([$cur.password_min_length // 6, 8] | max),
      mailer_subjects_confirmation: "Your Exponential News login link",
      mailer_templates_confirmation_content: $confirmation,
      mailer_subjects_magic_link: "Your Exponential News login link",
      mailer_templates_magic_link_content: $magic_link,
      mailer_subjects_recovery: "Reset your Exponential News password",
      mailer_templates_recovery_content: $recovery,
      mailer_subjects_email_change: "Confirm your new email for Exponential News",
      mailer_templates_email_change_content: $email_change
    }
  + (if $confirm != null and ($urls | index($confirm)) == null
     then {uri_allow_list: ($urls + [$confirm] | join(","))} else {} end)
  | with_entries(select(.value != $cur[.key]))
  ')

# The Send Email Hook: News sends every auth email through Resend.
if [ -n "${SEND_EMAIL_HOOK_SECRET_FILE:-}" ]; then
  : "${NEWS_URL:?Set NEWS_URL too: the hook is <NEWS_URL>api/auth/send-email}"
  secret=$(tr -d '[:space:]' < "$SEND_EMAIL_HOOK_SECRET_FILE")
  if [[ $secret != v1,whsec_* ]]; then
    echo "$SEND_EMAIL_HOOK_SECRET_FILE doesn't hold a hook secret (v1,whsec_...)." >&2
    exit 1
  fi
  auth_patch=$(jq -c --arg uri "${NEWS_URL%/}/api/auth/send-email" --arg secret "$secret" \
    '. + {hook_send_email_enabled: true, hook_send_email_uri: $uri, hook_send_email_secrets: $secret}' <<<"$auth_patch")
fi

# --- Show, confirm, apply -----------------------------------------------------

echo "Project $REF"
if [ "$postgrest_patch" = '{}' ]; then
  echo "  Data API: news is already exposed ($schemas)"
else
  echo "  Data API: exposed schemas \"$schemas\" -> \"$(jq -r .db_schema <<<"$postgrest_patch")\""
fi
if [ "$auth_patch" = '{}' ]; then
  echo "  Auth: nothing to change"
else
  jq -r --argjson cur "$auth" 'to_entries[] |
    if .key == "hook_send_email_secrets" then "  Auth: hook_send_email_secrets -> (set)"
    elif (.key | startswith("mailer_templates_")) then "  Auth: \(.key) -> supabase/templates"
    else "  Auth: \(.key): \($cur[.key] | tojson) -> \(.value | tojson)" end' <<<"$auth_patch"
fi
[ -z "${NEWS_URL:-}" ] && echo "  (NEWS_URL not set: redirect URLs left as they are)"
[ -z "${SEND_EMAIL_HOOK_SECRET_FILE:-}" ] && echo "  (SEND_EMAIL_HOOK_SECRET_FILE not set: email sender left as it is)"

if [ "$postgrest_patch" = '{}' ] && [ "$auth_patch" = '{}' ]; then exit 0; fi
if [ "$YES" != "--yes" ]; then
  read -r -p "Apply? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Nothing changed."; exit 1; }
fi

[ "$postgrest_patch" = '{}' ] || api PATCH /postgrest "$postgrest_patch" >/dev/null
[ "$auth_patch" = '{}' ] || api PATCH /config/auth "$auth_patch" >/dev/null
echo "Applied."
