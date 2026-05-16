# Toolkit roadmap

> What this doc is: a candidates catalog for the next agent-first tools
> that fit the system-janitor ethos. Sibling thinking to
> [`contracts.md`](./contracts.md) and
> [`machine-modes.md`](./machine-modes.md).
>
> What this doc is **not**: a build plan, a schedule, or a promise. No
> entry here is committed work. CHANGELOG owns commitments; this file
> owns the menu.

The repo currently ships two Linux-only Bash tools — `system-janitor.sh`
(disk/cache cleanup) and `system-updater.sh` (apt). They share an agent
contract: capability discovery, JSONL audit trail, atomic state writes,
`flock` single-instance, `--dry-run` default for destructive paths,
machine-mode `--report`/`--health`/`--health-acknowledge`, schemas under
`schemas/`, and smoke tests with capability-completeness probes.

> ## Decision log (2026-05-16, overrides recommendations below)
>
> This document was drafted assuming a Bash + Go split. After
> enumeration, the project reversed: **stay Bash, stay Linux-specific.**
>
> Reasoning, terse:
>
> 1. Of the 15 candidates below, only ~3-4 are *genuinely* cross-OS
>    (x509 parsing, file hashing, NTP probing, regex secret scanning).
>    The rest sell a Go veneer over N Linux-shaped backends —
>    `chronyc` vs `w32tm`, `/proc/net/tcp` vs Windows IP Helper, etc.
>    That isn't portability, that's three tools wearing one name.
> 2. Autonomous LLM agents operate **Linux** servers. macOS/Windows
>    are dev machines, not the deployment target. Cross-OS reach is
>    a hypothetical benefit; readable-source bash is a felt one.
> 3. Bash preserves the ethos: agents `cat` the source and adapt
>    during incident response. Go binaries are opaque. Hot-patching
>    a script in place is a real affordance we'd lose.
> 4. One contract implementation, not two. No build pipeline, no
>    binary-vs-source skew, no Go-shared-lib to keep in sync with
>    `system-janitor.sh` and `system-updater.sh`.
>
> What this means for the catalog:
>
> - Every candidate below is built in **Bash**, Linux-only, mirroring
>   the `system-janitor.sh` / `system-updater.sh` conventions.
> - The `language fit` line in each stanza records the original
>   deliberation but does not override this decision.
> - The §"Language recommendation: Bash vs Go" matrix is preserved
>   as the deliberation that produced this reversal. Read it as
>   history, not direction.
> - §"Lean-wedge proposal" has been rewritten in place.
>
> Revisit if and only if we hit a real wall on Linux. We will not.

The pivot that produced this doc — *"I like go binaries too… so we
can retool into being OS agnostic"* — was the working hypothesis.
The Decision log above is the conclusion.

## Selection criteria

A candidate earns a slot only if it satisfies all six:

1. **Emits structured truth before mutating.** Default mode is a
   `--report --json`-shaped read-only inventory. Mutation is opt-in.
2. **Idempotent or reversible.** Running twice produces the same
   end-state, or each mutation has a documented inverse (and the
   inverse also honors `--dry-run`).
3. **Lock-protected, single-instance.** `flock` (or its Go equivalent
   via `flock(2)` / `LockFileEx`) on a per-tool lock file. Code `1`
   reserved for "another instance running".
4. **Honors the agent contract.** `--version --json` with sorted
   `capabilities[]`, `--health --json` with named checks,
   `--health-acknowledge` baseline, JSONL append-only state under
   `~/.local/state/<tool>/`, atomic tmp+rename for snapshots, frozen
   exit codes (0/1/2/3/4/5 plus tool-specific).
5. **Hermetic test mode.** The smoke suite can drive it end-to-end
   without root, without network, and without touching the host. If
   testing requires "well, on a real machine…", it doesn't ship.
6. **Read-only by default.** Destructive paths require `--apply`. No
   tool auto-remediates on import.

A candidate that can't meet all six gets reshaped or dropped, not
grandfathered.

## Candidate catalog

Stanzas are compact on purpose. Risk profile, OS scope, language fit,
agent value, prior art, and the questions that would actually bite
during design.

---

### cert-watch

TLS/PKI expiry scanner. Walks a configured set of hosts/ports and/or
filesystem paths (`/etc/ssl`, `/etc/letsencrypt/live`, Kubernetes
secrets dirs), parses x509, reports days-to-expiry per cert.

- Risk: **read-only**.
- OS: **cross-os-including-windows** (x509 is x509).
- Language: **go**. `crypto/x509` is in the standard library; `openssl
  x509 -enddate` in Bash is brittle and pre-1.1 vs 3.x output drifts.
- Agent value: **high**. Cert expiry is the canonical "silent
  outage at 3am" failure that pre-deploy probes catch cheaply.
- Prior art: `certbot certificates`, `cert-manager`, `ssl-cert-check`
  (Bash), `cfssl`. None expose a stable JSON contract suitable for
  an unsupervised agent.
- Hard parts: SNI selection per host, STARTTLS variants (SMTP/IMAP/
  LDAP), client-cert-required endpoints (skip vs warn?), CT-log
  cross-check (probably out of v0).

### disk-health

SMART attributes + filesystem usage probe. Combines `smartctl -A
--json` (where available) with per-mount usage and inode pressure.

- Risk: **read-only**.
- OS: **cross-os-including-windows**. SMART is universal; access path
  differs (`/dev/sd*` vs `\\.\PhysicalDrive*`).
- Language: **go**. Cross-OS device enumeration is painful in Bash.
  Wrap `smartctl` rather than reimplement the protocol.
- Agent value: **high**. Reallocated-sector growth and 90%-full
  mounts are the two cheapest pre-failure signals on a long-lived host.
- Prior art: `smartmontools`, `node_exporter`'s smartmon collector,
  `zfs-zed`. We are not competing with Prometheus; we are the
  point-in-time agent probe.
- Hard parts: requires root or `CAP_SYS_RAWIO` for SMART; degrade
  gracefully when unavailable. NVMe attribute set differs from SATA.
  Software RAID hides member devices.

### time-drift

NTP/chrony/systemd-timesyncd/w32time skew probe. Reports offset,
stratum, last-sync age, and whether the host is actively synchronizing.

- Risk: **read-only**.
- OS: **cross-os-including-windows**.
- Language: **go**. SNTP query is ~50 lines of `net.UDPConn`; Bash
  shelling out to `chronyc`/`timedatectl`/`w32tm` and reconciling
  three output formats is a worse implementation.
- Agent value: **high**. Clock skew silently corrupts TLS handshakes,
  TOTP, log correlation, and Kerberos. Agents need a binary signal.
- Prior art: `chronyc tracking`, `timedatectl status`, `w32tm /query`,
  `ntpdate -q`. All human-formatted.
- Hard parts: do we *query* a public NTP server ourselves, or only
  inspect the local daemon? (Recommend: inspect local, optionally
  cross-check against one configured peer. Querying pool.ntp.org by
  default is rude.)

### service-health

Cross-init unit-status probe. systemd on Linux, launchd on macOS,
`sc.exe` / Service Control Manager on Windows.

- Risk: **read-only**.
- OS: **cross-os-including-windows**.
- Language: **go**. Three completely different IPC mechanisms;
  Bash gives nothing useful on macOS or Windows.
- Agent value: **medium**. Most agents care about a small named set
  of services, not all of them. Value is the cross-OS uniform output.
- Prior art: `systemctl --failed`, `launchctl list`, PowerShell
  `Get-Service`. No unified view.
- Hard parts: what counts as "failed" on launchd (exit code N is
  normal for some agents)? Per-user vs system buses on systemd.

### net-health

Listening-ports inventory, established-connection summary, DNS
resolver sanity (resolve a known name, time it, compare against
`/etc/resolv.conf` declared servers).

- Risk: **read-only**.
- OS: **cross-os-including-windows**.
- Language: **go**. `net.Listen`/`net.Dial` and `/proc/net/tcp` style
  parsers are fine, but Windows wants iphlpapi; Bash can't reach there.
- Agent value: **medium**. Useful as a "what is this box exposing"
  sanity check before/after config changes.
- Prior art: `ss -tlnp`, `netstat`, `lsof -i`, `Get-NetTCPConnection`.
- Hard parts: process-name attribution requires root on Linux for
  other users' sockets. Degrade to "anonymous listener on :N".

### proc-watch

Restart-loop detector, zombie reaper inventory, RSS-hog top-N. Reads
`/proc` snapshots (or `kinfo_proc`/`NtQuerySystemInformation`) and
diffs against a small persisted history.

- Risk: **read-only**.
- OS: **cross-os-including-windows** in principle; v0 probably **unix**.
- Language: **go**. Persisted history wants real serialization and
  atomic writes; Bash with `ps` + awk is a regression from janitor's
  state-file discipline.
- Agent value: **medium**. Restart loops are common, hard to spot
  by eye, and trivial to detect from PID/start-time diffs.
- Prior art: `monit`, `supervisord`, `systemd`'s own restart counters.
  We are not a supervisor; we are the read-only observer.
- Hard parts: defining "restart loop" without false positives on
  legitimately short-lived workers (cron, build agents). Threshold
  config.

### integrity-watch

File-hash baseline + drift detection over a configured path set.
AIDE-lite, agent-shaped output.

- Risk: **mutating-reversible** (the baseline is the only mutation;
  it's a single file, atomic write, trivially regenerable).
- OS: **cross-os-including-windows**.
- Language: **go**. Real concurrency for hashing large trees;
  `sha256sum | sort | diff` in Bash is fine for a homedir, painful
  for `/etc` + `/usr/local`.
- Agent value: **medium**. Higher in security-conscious deployments.
- Prior art: **AIDE** (well-established, GPL-2.0, Linux/BSD, text
  config + binary DB; see <https://aide.github.io/>), **Tripwire**
  (commercial heritage), **samhain**. AIDE is mature; we are not
  trying to replace it. We are providing the agent-contract
  wrapper around the same idea with a smaller, JSON-native surface.
- Hard parts: scope creep. The temptation to add "and also detect
  rootkits" turns this into chkrootkit. Stay narrow: hash the paths
  you were told to hash, emit drift, exit.

### log-audit

Failed-login enumeration, sudo anomaly summary, journal error-rate
spike detection. Reads `journalctl`, `/var/log/auth.log`,
`/var/log/secure`.

- Risk: **read-only**.
- OS: **linux-only** (journalctl + Linux auth-log conventions).
- Language: **bash**. The data sources are Linux-specific text/
  binary logs; jq + journalctl `--output=json` does the job. Go buys
  nothing here.
- Agent value: **medium**. Standard tripwire signal for "is this
  host under attack or misconfigured".
- Prior art: `fail2ban` (mutating), `logwatch`, `aureport`. We are
  read-only; we report, fail2ban acts.
- Hard parts: journalctl access for non-root users (group
  `systemd-journal` on Debian/Ubuntu). PAM log formats drift between
  distros.

### firewall-audit

Read-only nftables/iptables/ufw/firewalld policy diff. Renders the
active ruleset as canonical JSON; diffs against a configured baseline
file.

- Risk: **read-only**.
- OS: **linux-only**.
- Language: **bash**. `nft -j list ruleset`, `iptables-save`, `ufw
  status verbose`, `firewall-cmd --list-all-zones` are all Linux-
  specific shell tools.
- Agent value: **medium**. Catches "someone opened :22 to 0.0.0.0/0
  three days ago and no-one remembers why".
- Prior art: `nft`, `iptables-save`, OpenSCAP firewall profile checks.
- Hard parts: canonicalizing iptables `-save` output so reordering
  doesn't look like a diff. Multiple coexisting frontends on the
  same box (ufw on top of iptables on top of nftables) — pick one.

### secret-scan

Repo/disk regex sweep for accidentally-committed credentials, API
keys, SSH private keys.

- Risk: **read-only**.
- OS: **cross-os-including-windows**.
- Language: **go**. We do not want to be a slower `gitleaks`. If
  this ships, it ships as a thin agent-contract wrapper around a
  vendored rule pack with hermetic test fixtures.
- Agent value: **niche**. Most agents want this as part of a
  pre-deploy gate, not as a host probe. Possibly out of scope; the
  ecosystem (gitleaks, trufflehog, ripsecrets) is mature.
- Prior art: `gitleaks`, `trufflehog`, `detect-secrets`.
- Hard parts: false-positive rate is the whole game. Without a
  curated rule set, this is noise. **Lean toward dropping** unless
  we vendor an existing rule pack with attribution.

### backup-verify

Manifest-vs-actual integrity check for backup destinations. Given a
manifest of what should be there (paths, sizes, hashes, max age),
verifies the destination matches.

- Risk: **read-only**.
- OS: **cross-os-including-windows**.
- Language: **go**. Cross-OS path/stat handling and parallel hash.
- Agent value: **high** *in environments that have backups*.
  **niche** otherwise.
- Prior art: `restic check`, `borg check`, `rsnapshot` verification.
  Those check internal repo integrity. We check "is the thing the
  agent thinks it backed up actually on the destination".
- Hard parts: remote destinations (S3, rsync targets, SMB). v0 should
  be local-mount-only; remote is a v1 problem.

### kernel-cve

Cross-reference the running kernel (`uname -r`) against the distro's
USN/CVE feed. Reports "your kernel is N CVEs behind".

- Risk: **read-only**.
- OS: **linux-only**.
- Language: **either**. Bash + `curl` + `jq` is sufficient for a
  v0 against Ubuntu USN JSON or Debian Security Tracker. Go pays
  off if we want offline-cached feeds with signature verification.
- Agent value: **medium**. Pairs naturally with `system-updater`
  (updater says "kernel update available"; kernel-cve says "and
  here's the CVE backlog that closes").
- Prior art: `unattended-upgrades`, `needrestart`, Ubuntu Pro's
  `pro security-status`, `debsecan`.
- Hard parts: feed availability across distros. Ubuntu Pro covers
  ESM CVEs only under subscription; agent can't paper over that.

### container-sweep

Dangling Docker/Podman volume + image cleanup. Inventory by default,
prune with `--apply`.

- Risk: **mutating-destructive** (prune deletes data).
- OS: **cross-os where the engine exists** (Linux, macOS, Windows
  Docker Desktop).
- Language: **either**. The Docker/Podman CLIs are themselves
  cross-platform, so Bash wrapping is viable. Go gets us the
  Docker Engine API directly without shelling out.
- Agent value: **medium**. Overlaps with `system-janitor`'s existing
  `docker_prune` section — this would be a *deeper* sweep (named
  volumes referenced by no container, build-cache layers older than
  N days, dangling networks).
- Prior art: `docker system prune`, `podman system prune`,
  `dive`.
- Hard parts: "dangling but expensive to recreate" is a judgment
  call. Default to listing, never pruning, on first run.
- **Open question**: is this a new tool, or a v2 expansion of
  janitor's `docker_prune` section? Probably the latter.

### swap-pressure

Sustained swap activity + OOM-killer history. Diffs `/proc/vmstat`
samples across a small persisted history; greps `dmesg` /
`journalctl -k` for `oom-killer`/`Killed process`.

- Risk: **read-only**.
- OS: **linux-only** (`/proc/vmstat` is the whole interface).
- Language: **bash**. `awk` over `/proc/vmstat` and `journalctl -k
  --grep`; nothing here wants Go.
- Agent value: **medium**. Catches the "this host is paging itself
  to death" signal before the OOM-killer takes down something
  important.
- Prior art: `vmstat`, `sar`, `dmesg`.
- Hard parts: sample interval. A single snapshot is useless; we
  need persisted history (same JSONL discipline as janitor).

### cron-sanity

Orphaned cron entries, never-run jobs, last-run-too-long-ago.
Inventory `/etc/cron.*`, `/etc/cron.d`, user crontabs,
`systemctl list-timers`.

- Risk: **read-only**.
- OS: **linux-only**.
- Language: **bash**. Pure filesystem + `crontab -l` + `systemctl`
  parsing; Go is overkill.
- Agent value: **niche**. Useful in long-lived dev hosts where cron
  drift accumulates; less useful in immutable-infra environments.
- Prior art: none with an agent contract. `cronic` is human-facing.
- Hard parts: "never run" attribution. cron logs are unreliable;
  systemd timers expose `LastTriggerUSec` cleanly. Recommend
  scoping v0 to systemd timers and `/etc/cron.d` only.

---

## Language recommendation: Bash vs Go

> **Historical:** this matrix is the deliberation that produced the
> Decision log at the top of the file. The project chose Bash + Linux.
> Preserved unedited so the reasoning is auditable.

| Dimension | Bash | Go |
|---|---|---|
| Install footprint | Zero. Agent can `cat` source, edit in place. | Static binary; signed release artifact. |
| Cross-OS reach | Linux-only in practice (macOS bash 3.2, Windows nope). | Linux, macOS, Windows from one source tree. |
| JSON marshaling | `jq` or hand-rolled (fragile). | `encoding/json`, schema-aligned structs. |
| Concurrency | `&` + `wait` (no shared state). | Real `goroutine`/`chan`. |
| Audit-trail fit | Native (append `>>`, `flock`). | Native (`os.OpenFile`, `flock(2)`). |
| Test hermeticity | Subshell + tmpdir; very natural. | Equally natural (`t.TempDir()`). |
| Distribution | Clone the repo. | Release artifacts, checksums, signatures. |
| Read-back by humans | Trivial. | Requires `git`, not the binary. |

Decision rule:

- **Bash** for tools whose data sources are Linux-deep (`apt`, `dpkg`,
  `journalctl`, `/proc`, `/etc/cron.d`, `nft`, `iptables`).
- **Go** for tools whose protocols are universal (x509, SMART, SNTP,
  HTTP, filesystem hashing).
- **Either** is a real answer — but pick once per tool, not per
  function. A tool that's half-Bash-half-Go is two tools wearing
  one name.

Cost of mixing languages: the agent contract has to be honored
*twice* — once in shell idioms (today, in `system-janitor.sh` /
`system-updater.sh`) and once as a Go shared library. Net positive:
this forces the contract to become a real spec (capability strings,
exit codes, JSONL event shape, lock-file conventions) instead of
"whatever janitor.sh happens to do". That spec is value the project
needs anyway — see [Open questions](#open-questions).

## Lean-wedge proposal

Build **`cert-watch.sh` in Bash** first. Linux-only, mirroring
`system-janitor.sh` / `system-updater.sh` conventions.

Why this candidate, in this order:

1. **High value.** Cert expiry is the lowest-hanging operational
   fruit for an unsupervised agent. Every hour of work here pays
   for itself the first time it catches a 5-days-to-expiry cert.
2. **Linux-deep where it matters.** `/etc/letsencrypt/live/`,
   `/etc/ssl/certs/`, `update-ca-certificates`, OpenSSL command line.
   x509 parsing happens via `openssl x509 -noout -enddate`, which is
   already on every server.
3. **Small scope.** Read-only in v0. No `--apply` path. No
   destructive surface to design.
4. **Reuses the established contract.** `--version --json` with
   `capabilities[]`, `--report --json`, `--health --json`,
   `--health-acknowledge`, `flock`, atomic state writes, JSONL
   audit trail — same patterns as janitor and updater. Third tool
   to wear the contract; if it fits awkwardly, the contract has a
   problem the first two hid.
5. **Hermetic testing is trivial.** `openssl req -x509` generates
   self-signed certs into a tmpdir with arbitrary `-days`. No host
   state, no network, no clock games.

v0 surface sketch (illustrative, not frozen):

```
cert-watch.sh --report --json
cert-watch.sh --health --json
cert-watch.sh --version --json    # capabilities[] sorted, frozen
cert-watch.sh --scan --json       # one-shot scan, emits JSONL events
                                  # CERTWATCH_PATHS env, colon-separated
                                  # CERTWATCH_WARN_DAYS (default 30)
                                  # CERTWATCH_CRITICAL_DAYS (default 7)
```

No `--apply`. No renewal. No CT-log lookups. No host:port probing
(yet — that's a v1 conversation once we know the JSONL shape works
for filesystem certs).

Exit codes extend the shared set with two cert-specific codes
(candidate values, frozen once shipped):

- `8` — at least one cert in the warn window (default 30 days)
- `9` — at least one cert expired or unparseable

## What stays out of v1

- **Daemons.** Every tool runs to completion and exits. If you want
  a daemon, you want Prometheus.
- **Observability stacks.** We are not Prometheus, Grafana, Loki,
  or OpenTelemetry. We are point-in-time agent ops. If a candidate's
  natural form is "scrape me every 15s", it does not belong here.
- **Kernel modules.** eBPF, kprobes, anything that requires building
  against the running kernel. Out.
- **Auto-remediation without `--apply`.** Every mutating path is
  opt-in, explicit, and logged. No "smart" cleanups that "obviously"
  should happen by default.
- **Wrappers that add nothing.** If the underlying tool already emits
  good JSON (`smartctl --json`, `nft -j`, `journalctl -o json`), we
  re-shape and contract-wrap; we do not reimplement.

## Open questions

These are decisions the catalog can't make alone. Listing them so
the human can rule on them before binary #1 ships.

1. **Repo rename: now or later?** The repo is named `system-janitor`
   but the catalog above is broader than disk cleanup. Renaming the
   GitHub repo (e.g. `agent-frontier/agent-toolkit`) is cheap *now*
   (two tools, light external references) and expensive *later*
   (every tool's docs/links/cron lines accumulate). Recommendation:
   rename before binary #1 lands. Guessing — the user may have other
   reasons to keep the current name.

2. **Extract `pkg/agentcontract` before or after binary #2?** Two
   honest paths: (a) build `cert-watch` standalone, then refactor
   the contract code into a shared package when `disk-health` or
   `time-drift` starts; (b) extract the shared package up-front,
   even though we only have one Go consumer. Path (a) risks the
   contract code calcifying around cert-watch's shape; path (b)
   risks designing an abstract library for a use case we haven't
   built yet. Mild lean toward (a) — extract on the *second* Go
   tool, when we know what's actually shared vs cert-specific.

3. **Should `cert-watch` v0 ever attempt cert renewal?** Strong
   recommendation: no. v0 stays read-only. Renewal is ACME, which
   is a separate, large protocol surface with its own state, key
   material, and rollback story. If renewal ships, it ships as
   `cert-watch --apply --renew` in a v1+ release that passed
   independent review. v0's value proposition is the *observation*,
   not the action.

4. **Bash tools as Go too, eventually?** A future `system-janitor`
   v2 in Go would gain Windows reach (Docker Desktop, NuGet caches
   on Windows dev boxes) and lose the "agent can `cat` the source"
   property. Worth deciding *before* the bash codebase grows past
   ~2500 lines. Not urgent, but the question gets harder every
   feature.

5. **Do we publish a `capabilities[]` *registry*?** Currently each
   tool's `capabilities[]` is documented in that tool's
   `machine-modes.md`. Once we have 3+ tools and a shared Go
   library, a central registry of capability strings (with
   reservation rules) prevents name collisions. Defer until tool #3.
