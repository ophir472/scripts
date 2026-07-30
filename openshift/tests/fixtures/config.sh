#!/usr/bin/env bash
# Fixture config used only by tests/run-tests.sh, swapped in for the real config.sh.
# Format: "env|shortname|server|namespace|project"
CLUSTERS=(
  "dev|t1|https://fake-dev.example.com:6443|qwe-rty-checkout-111111|checkout"
  "dev|t1|https://fake-dev.example.com:6443|sm-controlplane-222222|"
  "prod|p1|https://fake-prod.example.com:6443|qwe-rty-checkout-111111|checkout"
  "prod|p1|https://fake-prod.example.com:6443|sm-controlplane-222222|"
)
USER_DEFAULT="testuser"
USER_PROD="produser"
DISCOVERY_DOMAIN="ecs.dyn.nsroot.net"
