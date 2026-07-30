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

# REQUIRED before running `oo.sh -a discover`: the domain it appends to build
# a cluster's API URL: https://api.<identifier>.<DISCOVERY_DOMAIN>
# Left blank on purpose -- fill in your own domain. discover will refuse to
# run while this is empty.
DISCOVERY_DOMAIN=""

# Each entry: "env|shortname|server|namespace|project" (pipe-delimited -- the
# server field is a URL and contains colons, so ':' can't be the delimiter)
#   env       - dev | uat | prod (drives which username logs in, and -e filtering)
#   shortname - short cluster id, derived from the discovered identifier (used with -c)
#   server    - API server URL
#   namespace - a namespace discovery found on that cluster
#   project   - project name derived from the namespace (may be empty)
# One row per (cluster, namespace) pair -- a cluster with 5 namespaces gets 5 rows.
# These are illustrative placeholders; run discover to replace them with your own.
CLUSTERS=(
  "dev|abc12345d|https://api.clusterabc12345d.example.com|qwe-rty-checkout-111111|checkout"
  "dev|abc12345d|https://api.clusterabc12345d.example.com|sm-controlplane-222222|"
  "prod|xyz67890p|https://api.clusterxyz67890p.example.com|qwe-rty-checkout-333333|checkout"
)
