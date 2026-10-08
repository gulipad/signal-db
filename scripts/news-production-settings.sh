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
#   Auth      with NEWS_URL: <NEWS_URL>auth/confirm** added to the redirect URLs
#   Auth      with SMTP_HOST: a custom SMTP sender (without one, Supabase only
#             delivers auth emails to the organization's own team members)
#
# Usage, from your own terminal (not through an AI tool, so the token stays
# with you):
#
#   export SUPABASE_ACCESS_TOKEN=...   # https://supabase.com/dashboard/account/tokens
#   export NEWS_URL=https://news.goexponential.org/                 # optional
#   export SMTP_HOST=smtp.resend.com SMTP_PORT=465 SMTP_USER=resend \
#          SMTP_PASS=<resend api key> SMTP_ADMIN_EMAIL=news@goexponential.org \
#          SMTP_SENDER_NAME="Exponential News"                       # optional
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
      password_min_length: ([$cur.password_min_length // 6, 8] | max),
      mailer_subjects_confirmation: "Confirm your Exponential News account",
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

if [ -n "${SMTP_HOST:-}" ]; then
  : "${SMTP_PORT:?} ${SMTP_USER:?} ${SMTP_PASS:?} ${SMTP_ADMIN_EMAIL:?} ${SMTP_SENDER_NAME:?}"
  # smtp_port goes as the type the API returns (a number when unset, as in
  # Supabase's own SMTP guide).
  auth_patch=$(jq -c --argjson cur "$auth" \
    --arg host "$SMTP_HOST" --arg port "$SMTP_PORT" --arg user "$SMTP_USER" --arg pass "$SMTP_PASS" \
    --arg admin "$SMTP_ADMIN_EMAIL" --arg name "$SMTP_SENDER_NAME" \
    '. + {smtp_host: $host,
          smtp_port: (if ($cur.smtp_port | type) == "string" then $port else ($port | tonumber) end),
          smtp_user: $user, smtp_pass: $pass, smtp_admin_email: $admin, smtp_sender_name: $name}' <<<"$auth_patch")
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
    if .key == "smtp_pass" then "  Auth: smtp_pass -> (set)"
    elif (.key | startswith("mailer_templates_")) then "  Auth: \(.key) -> supabase/templates"
    else "  Auth: \(.key): \($cur[.key] | tojson) -> \(.value | tojson)" end' <<<"$auth_patch"
fi
[ -z "${NEWS_URL:-}" ] && echo "  (NEWS_URL not set: redirect URLs left as they are)"
[ -z "${SMTP_HOST:-}" ] && echo "  (SMTP_HOST not set: email sender left as it is)"

if [ "$postgrest_patch" = '{}' ] && [ "$auth_patch" = '{}' ]; then exit 0; fi
if [ "$YES" != "--yes" ]; then
  read -r -p "Apply? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Nothing changed."; exit 1; }
fi

[ "$postgrest_patch" = '{}' ] || api PATCH /postgrest "$postgrest_patch" >/dev/null
[ "$auth_patch" = '{}' ] || api PATCH /config/auth "$auth_patch" >/dev/null
echo "Applied."
