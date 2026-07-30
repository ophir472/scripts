#!/usr/bin/env bash
# Shared OpenShift configuration: clusters and usernames.
# Source this from every openshift/*.sh script. Never put passwords here —
# they're always prompted at runtime.
#
# Normally you don't hand-edit CLUSTERS: run `oo.sh -a discover -f <id-list-file>`
# to regenerate it (see tests/fixtures/cluster-ids.txt for the input format).

# Usernames. Passwords are always prompted at runtime, never stored.
USER_DEFAULT="my-username"
USER_PROD="my-prod-username"

# Domain `oo.sh -a discover` appends to build a cluster's API URL:
# https://api.<identifier>.<DISCOVERY_DOMAIN>
DISCOVERY_DOMAIN="ecs.dyn.nsroot.net"

# Each entry: "env|shortname|server|namespace|project" (pipe-delimited -- the
# server field is a URL and contains colons, so ':' can't be the delimiter)
#   env       - dev | uat | prod (drives which username logs in, and -e filtering)
#   shortname - short cluster id, derived from the discovered identifier (used with -c)
#   server    - API server URL
#   namespace - a namespace discovery found on that cluster
#   project   - project name derived from the namespace (may be empty)
# One row per (cluster, namespace) pair -- a cluster with 5 namespaces gets 5 rows.
CLUSTERS=(
  "dev|swd52u|https://api.namicgswd52u.${DISCOVERY_DOMAIN}|qwe-rty-checkout-111111|checkout"
  "dev|swd52u|https://api.namicgswd52u.${DISCOVERY_DOMAIN}|sm-controlplane-222222|"
  "prod|gtd128d|https://api.namicggtd128d.${DISCOVERY_DOMAIN}|qwe-rty-checkout-333333|checkout"
)
