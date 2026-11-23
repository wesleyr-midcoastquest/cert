# Changelog

## 0.2.5 (Nov 2026): wait for the targets before breaking

- **Before the break, CERT waits (up to 5 minutes) until every target
  answers WinRM again.** On a test lab, one DC (the one running Tailscale)
  stopped answering for at least a minute right after the setup step, which
  changes each machine's firewall. The break couldn't connect, so dc-time-skew
  never broke anything. Why it stops answering isn't known yet; the
  timeline's new `targets ready` event says how long each target took.
- The break itself keeps trying to connect for 5 minutes, not 60 seconds.
- **"Can't reach" says why**: a port that didn't answer, a refused logon
  (with Windows' reason), or a machine with another VM's MAC, and how many
  attempts over how long.
- **A failed break is its own state, `BreakFailed`.** Before, the run looked
  normal: "Check the break took" ran and reported expected failures as
  "not seen yet", as if the break might still show. Now the menu says the
  break failed and to revert; the check, the handover and the clock refuse.
- `Invoke-CertTarget` takes `-TimeoutSeconds`. sysvol-replication-disabled's
  `verify.ps1` already passed it, so that call threw every time: its
  `sysvol-change-arrives` check could never pass.

## 0.2.4 (Nov 2026): SYSVOL after a revert

- **Every revert now ends with an authoritative SYSVOL sync from the PDC
  emulator** (`Repair-CertSysvol`, Microsoft KB 2218556). Rolling a DC back
  to a snapshot gives it a new VM-Generation ID. DFS Replication takes that
  as a restore and waits to copy SYSVOL from a partner. When every DC was
  rolled back, every DC waits for another, and SYSVOL stays stuck in initial
  sync (state 2, event 4614; lab check SYSVOL-002). All copies are the same
  snapshot, so declaring the PDC's copy the master loses nothing. It's
  skipped when SYSVOL is already Normal everywhere.
- The snapshot test does the same, and reports it.
- Menu 8 runs it on demand.

## 0.2.3 (Nov 2026)

- Pre-flight reads the VM storage's use again: storage over 2 GB overflowed
  an integer, so the check always said it couldn't read it.

## 0.2.2 (Nov 2026): consistent RAM snapshots without pausing

- The snapshot set is taken with every VM **unplugged** (network link down)
  instead of paused. QEMU can't continue a VM whose RAM was saved while it
  was paused ("Migration is not finalized yet"). Unplugged, the DCs still
  can't replicate between snapshots, so the set is still one moment of the
  lab. They're plugged back in when the last snapshot is done.
- A revert rolls every VM back (they come back unplugged, as snapshotted),
  then plugs them all in together.
- The storage-use warning now says why it couldn't read the storage.

## 0.2.1 (Nov 2026): fixes from the first real run

- After a RAM snapshot, a VM is resumed whatever QEMU calls its paused
  state (it may be `postmigrate`, not `paused`), and CERT checks it's
  running again. The first real run left the DCs frozen, and the next step
  couldn't reach them.
- After the snapshot, CERT waits up to 5 minutes for every VM to answer
  WinRM before it goes on. If setup fails, the message says the run is open,
  nothing was broken, and to revert.

## 0.2.0 (Nov 2026): the fixer works on MGMT

Written for MidCoast Lab compatibility 1.6 (LAB-261121-00 and later), which
has the snapshot rights and the CERT lock. A 1.5 lab works with the rights
added by hand (README).

- **No separate assessor needed.** The fixer signs in to MGMT with the
  engagement account and works from there (`assessor.role: MGMT`, the new
  default). A W11 or a fixed address still works; with no active W11, CERT
  falls back to MGMT and says so.
- **MGMT is never rolled back, so CERT cleans up there itself.** On revert it
  signs out the engagement account's sessions, removes any Remote Desktop
  grant it gave (a `standard` account gets MGMT's Remote Desktop Users for
  the run), and deletes the account's profile.
- The handover tells the fixer that MGMT's own settings, `C:\MidCoastLab` and
  the pipeline are out of scope.
- Run folders are readable only by the account running CERT (and SYSTEM):
  they hold the engagement password and, in a blind run, the scenario.
- **Lock file is JSON** (`scenario`, `started`, `snapshot`, `run`, `by`), as
  the lab's pipeline reads it. A blind run's lock doesn't name its scenario.
  Pre-flight warns when `lock_path` differs from lab.yaml's
  `handover.cert_lock_path`. A 0.1 plain-text lock is still read.
- A module target must be in the snapshot set: CERT refuses one that
  resolves to MGMT.
- Per-site Proxmox tags (lab 1.6) are used from the inventory.
  `cert-snapshots.sh` now matches `midcoast-lab` and every `midcoast-lab-<site>`
  by default.
- All six modules 1.0.1: briefings no longer say "work from the assessor".
  In `admin-passwords-changed`, MGMT's configuration (not MGMT) is out of scope.
- CI runs on `master`.

## 0.1.0 (Nov 2026): first release

Written for MidCoast Lab compatibility 1.5 (LAB-261105-04). Needs snapshot
rights on the lab's Proxmox role
([midcoast-labs#23](https://github.com/wesleyr-midcoastquest/midcoast-labs/issues/23));
the README has the one-line fix until the lab ships it.

- Control panel (`Start-Cert.ps1`): update modules from this repo and extra
  git sources (shown first, fast-forward only); start a scenario or a
  surprise one; snapshot test; snapshot sets; past runs and reports.
- Runs, each with a record and a report:
  - pre-flight, including the lab's own validation
  - one consistent snapshot set of every lab VM except MGMT, with RAM
  - assessor access and the engagement account
  - break, then a check that it took
  - clock, milestones and notes
  - repair check: lab validation plus the module's checks
  - revert, with clocks set
- Six modules: `fsmo-holder-lost`, `dc-locator-records-deleted`,
  `dc-time-skew`, `sysvol-replication-disabled`, `admin-passwords-changed`,
  `gpo-deleted`.
- `tools/cert-snapshots.sh` for the Proxmox host owner; `tools/Test-CertModule.ps1`
  and offline tests, run in CI.

Not yet tested against a live lab: the first runs are the test.
