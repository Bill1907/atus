#!/bin/sh
# atus plugin: OpenRouter credits, through OpenRouter's official API.
# https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits
#
# Needs a *management* key (openrouter.ai → Settings → Management Keys), stored in
# the login keychain rather than in a file:
#   security add-generic-password -a "$USER" -s atus-openrouter -w 'sk-or-v1-...'
# Needs jq (built into macOS 15+; on macOS 14: brew install jq).

key=$(security find-generic-password -s atus-openrouter -w 2>/dev/null)
if [ -z "$key" ]; then
  echo "키체인에 atus-openrouter 키가 없어요" >&2
  exit 1
fi

response=$(curl -sS --max-time 20 -H "Authorization: Bearer $key" https://openrouter.ai/api/v1/credits) || {
  echo "OpenRouter에 연결하지 못했어요" >&2
  exit 1
}

# Errors come back as {"error": {"message": ...}}; show that message in the panel.
if ! printf '%s' "$response" | jq -e '.data.total_credits' >/dev/null 2>&1; then
  printf '%s' "$response" | jq -r '.error.message // "예상과 다른 응답"' >&2
  exit 1
fi

printf '%s' "$response" | jq '{
  windows: [{
    label: "크레딧 사용",
    percent: (if .data.total_credits > 0 then .data.total_usage / .data.total_credits * 100 else 0 end)
  }],
  details: [
    { label: "남은 크레딧", value: ("$" + ((.data.total_credits - .data.total_usage) * 100 | round / 100 | tostring)) },
    { label: "총 충전", value: ("$" + (.data.total_credits | tostring)) }
  ]
}'
