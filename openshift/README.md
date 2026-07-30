# oo.sh — OpenShift multi-cluster helper

One CLI (`oo.sh`) for working across many OpenShift clusters (dev/uat/prod) at
once: check namespace quota, search secret values, or auto-discover clusters
into config. No password is ever stored — you're prompted each run.

## Requirements

- `bash` (works fine on the stock 3.2 that ships with macOS — no need to
  install a newer one)
- `oc` (the OpenShift CLI), logged out is fine — `oo.sh` logs in itself
- `jq`
- `awk` (stock on macOS/Linux)

Check you have them:

```
command -v oc jq awk
```

If `jq` is missing: `brew install jq` (macOS) or your distro's package
manager on Linux.

## Install

There's nothing to build — it's plain shell scripts. Just make sure they're
executable (they already are if you got this via git, since the executable
bit is committed):

```
cd openshift
chmod +x oo.sh lib/*.sh tests/*.sh tests/mock-oc
./oo.sh -h        # sanity check
```

## Add `oo` to your PATH

Pick one. All examples assume you're in the `openshift/` directory.

**Option A — symlink into a directory already on PATH** (recommended, keeps
the script in the repo so `git pull` updates it in place):

```
mkdir -p ~/bin
ln -s "$(pwd)/oo.sh" ~/bin/oo
```

Then make sure `~/bin` is on PATH — add this to `~/.zshrc` (or `~/.bashrc`)
if it isn't already:

```
export PATH="$HOME/bin:$PATH"
```

Reload your shell (`source ~/.zshrc`) and you can now run `oo` from anywhere:

```
oo -a quota -e uat
```

**Option B — add this directory to PATH directly:**

```
echo 'export PATH="'"$(pwd)"':$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Since the file is named `oo.sh`, you'd invoke it as `oo.sh -a quota` (rename
to `oo` first, or symlink as in Option A, if you want the bare `oo` command).

**Option C — alias, no PATH changes:**

```
echo "alias oo='$(pwd)/oo.sh'" >> ~/.zshrc
source ~/.zshrc
```

## Setup

Everything lives in `config.sh`:

- `USER_DEFAULT` / `USER_PROD` — your username for non-prod and prod clusters
  (passwords are always prompted, never saved).
- `DISCOVERY_DOMAIN` — the domain `oo.sh -a discover` appends to build a
  cluster's API URL: `https://api.<identifier>.<DISCOVERY_DOMAIN>`.
- `CLUSTERS` — the array of known clusters/namespaces/projects. You normally
  don't hand-edit this; see **Discovery** below.

First time setup:

1. Edit `USER_DEFAULT`, `USER_PROD`, `DISCOVERY_DOMAIN` in `config.sh`.
2. Make a text file with your cluster identifiers, one per line (see
   `tests/fixtures/cluster-ids.txt` for the format), e.g.:
   ```
   namicgswd52u
   namicggtd128d
   ```
3. Run `./oo.sh -a discover -f your-cluster-ids.txt` to populate `CLUSTERS`.

## Interactive mode

Run with no arguments at all:

```
./oo.sh
```

Walks you through: pick an action → pick environment(s) → pick project(s) →
optionally narrow down the cluster list → shows the exact equivalent command
and full cluster list → asks to confirm before logging into anything.

## Flag-driven mode

```
./oo.sh -a <action> [-e env|all] [-c cluster] [-n namespace] [-p project] [--insecure] [options]
```

### Selection flags (shared by every action)

| Flag | Meaning |
|---|---|
| `-e env` | `dev`, `uat`, `prod`, or `all` (default). Comma-separated list allowed: `-e dev,uat`. |
| `-c cluster` | Target cluster(s) by short name, overrides `-e`. Comma-separated: `-c t1,t2`. |
| `-n namespace` | Target exact namespace name(s). Without `-c`, searches every selected cluster and reports wherever it's found. Comma-separated allowed. |
| `-p project` | Only namespaces whose derived project matches. Comma-separated allowed. See **Project names** below. |
| `--insecure` | Pass `--insecure-skip-tls-verify` to `oc login`. |

With no `-e`/`-c` at all, the default is everything (`-e all`).

### Actions

**`-a quota`** — reports CPU/memory allocated vs. used per namespace.

```
./oo.sh -a quota                                # everything
./oo.sh -a quota -e uat
./oo.sh -a quota -c pr1 -n checkout-prod-482913
./oo.sh -a quota -p checkout                    # this project, across ALL envs
```

Writes one report file (default `./quota-report-<target>-<timestamp>.txt`,
override with `-o`): a SUMMARY section (per-namespace rows, per-cluster
subtotals, grand total) followed by an EXTENDED section (raw `oc get`/
`describe quota` output per namespace).

**`-a search <string>`** — searches base64-decoded secret values for a string.

```
./oo.sh -a search -e uat "my-secret-value"
./oo.sh -a search -c pr1 -n checkout-prod-482913 "api-key"
```

Prints `FOUND in [cluster/env]: namespace/secretname` for each match.

**`-a discover -f <file>`** — (re)populates `config.sh`'s `CLUSTERS` array.

```
./oo.sh -a discover -f cluster-ids.txt
./oo.sh -a discover -f cluster-ids.txt -o other-config.sh   # write elsewhere instead
```

Reads one cluster identifier per line (`#` comments and blank lines OK),
parses each into env + short name (see below), logs into every recognized
cluster, lists its namespaces, derives each namespace's project, and writes
the whole `CLUSTERS` array. If the target file already exists it's backed up
first as `<file>.bak.<timestamp>`.

**Identifier parsing**: an identifier like `namicgswd52u` is read from the
end — last letter is the env (`d`=dev, `u`=uat, `p`=prod, `s`=sit is silently
dismissed, anything else is skipped with a warning), the digits right before
it plus the 3 letters before *those* become the short name (`swd52u`). The
server URL is `https://api.<full identifier>.<DISCOVERY_DOMAIN>`.

**Known limitation**: discovery always *fully replaces* `CLUSTERS` from
whatever it successfully logs into this run — it does not merge with the
existing config. A mistyped password (dropping an entire env) or running with
a partial identifier list will silently drop clusters that aren't in this
run's successful set. The old file is backed up first, so recovery is
possible via the `.bak` file, but it's not automatic — always check the
"Skipped (login failed)" line in the output.

## More examples

Assuming `oo` is on your PATH (see **Add oo to your PATH** above; use
`./oo.sh` instead if not):

```sh
# Quota

oo -a quota                                    # every cluster, every namespace
oo -a quota -e dev                             # just the dev env
oo -a quota -e dev,uat                         # dev and uat, comma-separated
oo -a quota -c pr1                              # one specific cluster, all its namespaces
oo -a quota -c pr1,pr2                          # several specific clusters
oo -a quota -c pr1 -n checkout-prod-482913      # one namespace on one cluster
oo -a quota -n checkout-prod-482913             # that namespace, searched on every cluster
oo -a quota -p checkout                         # "checkout" project, across ALL envs
oo -a quota -p checkout,billing                 # multiple projects at once
oo -a quota -e uat -p checkout                  # "checkout" project, uat only
oo -a quota -e prod --insecure                  # skip TLS verification on login
oo -a quota -e uat -o ~/reports/uat-quota.txt   # custom output path

# Search

oo -a search -e uat "some-secret-value"
oo -a search -c pr1 "api-key-1234"
oo -a search -p checkout "db-password"          # only checkout-project namespaces
oo -a search -e all "leaked-credential"         # every cluster, every namespace

# Discover (rebuild config.sh)

oo -a discover -f cluster-ids.txt
oo -a discover -f cluster-ids.txt --insecure
oo -a discover -f cluster-ids.txt -o /tmp/preview-config.sh   # dry-run to a scratch file first

# Interactive (no flags)

oo
```

## Project names

Namespaces are expected to follow `word-word-PROJECT-123456` — exactly 6
trailing digits, with the project name being everything between the first two
words and those digits (the project itself can contain hyphens, e.g.
`my-project-2`). Namespaces that don't fit this shape (e.g. a fixed system
namespace, or a 5/7-digit suffix) simply have no project and show as `none` —
they're still included in `-e`/`-c` runs, just excluded from `-p` filtering.
This is computed live from the actual namespace name every run — it's never
read from `config.sh`, which only stores a discovery-time snapshot used to
build the interactive menu's env/project choices.

## Security notes

- Passwords are always prompted (`read -s`), never written to disk.
- Each cluster login uses an isolated temp kubeconfig — your real
  `~/.kube/config` is never touched.
- `oc login --password` does pass the password as a process argument, which
  is visible to other local users via `ps` for the moment the login runs.
  This is a limitation of `oc login` itself, not this script.

## Tests

```
./tests/run-tests.sh
```

Runs against a mock `oc` (`tests/mock-oc`) — no real cluster or credentials
needed. Covers CLI targeting logic, project-name extraction, discovery
parsing, and the interactive menu end to end.
