#!/usr/bin/env bash
set -euo pipefail

# Configuration: "name:server"
CLUSTERS=(
  "dev1:https://api.dev1.example.com:6443"
    "dev2:https://api.dev2.example.com:6443"
      # ... add all 10
        "prod1:https://api.prod1.example.com:6443"
        )

        # Usernames
        USER_DEFAULT="my-username"
        USER_PROD="my-prod-username"
        # Which cluster names are prod (matched by prefix)
        PROD_MATCH="prod"

        SEARCH_STRING="${1:?Usage: $0 <search-string>}"

        # Prompt once per username
        read -rsp "Password for $USER_DEFAULT: " PASS_DEFAULT; echo
        read -rsp "Password for $USER_PROD (prod): " PASS_PROD; echo

        for entry in "${CLUSTERS[@]}"; do
          NAME="${entry%%:*}"
            SERVER="${entry#*:}"

              if [[ "$NAME" == *"$PROD_MATCH"* ]]; then
                  USERNAME="$USER_PROD"; PASSWORD="$PASS_PROD"
                    else
                        USERNAME="$USER_DEFAULT"; PASSWORD="$PASS_DEFAULT"
                          fi

                            # Login (add --insecure-skip-tls-verify=true if needed)
                              if ! oc login "$SERVER" -u "$USERNAME" -p "$PASSWORD" >/dev/null 2>&1; then
                                  echo "[$NAME] login failed" >&2
                                      continue
                                        fi

                                          # Only namespaces you have access to
                                            NAMESPACES=$(oc get projects -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
                                              if [[ -z "$NAMESPACES" ]]; then
                                                  echo "[$NAME] no accessible projects" >&2
                                                      continue
                                                        fi

                                                          for NS in $NAMESPACES; do
                                                              oc get secrets -n "$NS" -o json 2>/dev/null | \
                                                                  jq -r '.items[] | .metadata.namespace + "/" + .metadata.name as $id |
                                                                        (.data // {}) | to_entries[] | [$id, .value] | @tsv' | \
                                                                            while IFS=$'\t' read -r id val; do
                                                                                  if printf '%s' "$val" | base64 -d 2>/dev/null | grep -qF "$SEARCH_STRING"; then
                                                                                          echo "FOUND in [$NAME]: $id"
                                                                                                fi
                                                                                                    done
                                                                                                      done
                                                                                                      done