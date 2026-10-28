#!/bin/sh
# Minimal atus plugin: prints usage in the JSON shape atus expects.
# Replace the fixed numbers with a call to your service (curl + jq, a CLI, ...).
#
# Register it in ~/.config/atus/providers.json:
#   { "providers": [ { "id": "demo", "name": "Demo", "command": "~/atus-plugins/demo.sh", "icon": "sparkles" } ] }
#
# On failure, print a short reason to stderr and exit non-zero; atus shows the last
# stderr line in the panel.

reset=$(date -u -v+5H +%Y-%m-%dT%H:%M:%SZ)

cat <<EOF
{
  "plan": "Demo",
  "windows": [
    { "label": "5시간", "percent": 42, "resetsAt": "$reset" },
    { "label": "주간", "percent": 18 }
  ],
  "details": [
    { "label": "남은 크레딧", "value": "\$12.00" }
  ]
}
EOF
