# CERT

Break/fix scenarios for a [MidCoast Lab](https://github.com/MidCoast-Labs/midcoast-labs).

CERT breaks a working lab in one specific way, such as losing the FSMO role
holder, deleting the DNS locator records, skewing a DC's clock or changing
the admin passwords. Someone then assesses it and repairs it, and CERT checks
whether the repair is right. When the exercise is over, it puts the lab back
exactly as it was just before the break. You can run the same scenario again
and again, to test a tool, a procedure or a person against the same starting
point.

It's built for running a lab the way you'd handle a customer environment:

- The **impacted owner** runs CERT on the lab's management machine (MGMT),
  breaks the lab, and hands over the way a customer would: a description of
  the symptoms, and an account.
- The **fixer** comes in blind. They sign in to MGMT by Remote Desktop with
  the account the owner hands over, and work from there. A separate
  workstation isn't needed. A lab Windows machine, such as the Phase 2 W11,
  can be used instead (`assessor.role` in `cert.config.yaml`).

> **A lab, not production.** CERT runs as a domain administrator, breaks things on
> purpose, and rolls VMs back. Point it only at a MidCoast Lab. MIT licensed
> ([LICENSE](LICENSE)); security reports: [SECURITY.md](SECURITY.md).

## How a run works

```text
pre-flight -> snapshot -> open access for the fixer -> engagement account -> break
   -> check the break took -> hand over (clock starts) -> fixer works -> check the repair
   -> revert to the snapshot
```

1. **Pre-flight.** CERT checks that:
   - no other run is open, and no rotation or MGMT handover is under way
   - the module's needs are met (CERT and lab versions, how many DCs)
   - every VM in the set is running and reachable
   - **the lab passes its own validation**, because a scenario has to start
     from a working lab
   - there's room on the VM storage
2. **Snapshot.** Every lab VM except MGMT (the DCs, and later ADES and W11)
   is snapshotted under one name, `CERT-<YYMMDD>-<HHMM>-<NN>`, RAM included.
   CERT pauses all of them first and resumes them afterwards, so the set
   captures one consistent moment of the lab: no DC can replicate a change
   that another DC's snapshot missed. MGMT stays out, because it holds the
   run, the vault and the ledger.
3. **Access for the fixer.** Most tools use WinRM over HTTP (5985), but the
   lab only allows WinRM over HTTPS (5986). On every VM in the set, CERT
   opens WinRM over HTTP, Remote Desktop and ping from the machine the fixer
   works on.
4. **Engagement account.** If the module asks for one, CERT creates the
   account the owner hands to the fixer: a domain admin, an ordinary user, or
   none at all.
   - A domain admin account can use Remote Desktop to MGMT already: the lab
     grants it to its Tier 0 group.
   - An ordinary user gets MGMT's Remote Desktop Users group for the run.
5. **Break.** The module's `break.ps1` runs. CERT then checks that the break
   took, by looking for the lab validation failures and the module's own
   check failures that the module said would appear.
6. **Hand over.** The owner shows the briefing and the account (menu:
   *Show the handover*) and starts the clock.
   - During the work, the owner can record milestones such as "cause
     identified", and notes.
   - When the fixer says it's fixed, *Check the repair* runs the lab's own
     validation plus the module's checks. Any Critical or High failure means
     not fixed yet.
7. **Revert.** Every VM in the set is stopped, then all are rolled back to
   the snapshot, then started again. Stopping them all first means a rolled-back
   DC can't pick up the broken state from one that hasn't been rolled back yet.
   - Their clocks are set from MGMT. A rolled-back VM wakes up at the
     snapshot's time.
   - The break, the extra access and the engagement account are all gone,
     since they happened after the snapshot.
   - MGMT isn't rolled back, so CERT cleans up there itself: it signs out the
     engagement account's sessions, removes any Remote Desktop grant, and
     deletes the account's profile.
   - Keep the snapshot set to run again from the same point, or delete it.

Each run has a record and a report (`report.md`) in `C:\MidCoastLab\cert-runs\<run id>\`:
the module and version, the timeline, time to cause, time to repair, and the
result of every check. The report includes the module's reference solution
once the run is reverted.

**Surprise mode** picks a random module (optionally capped by difficulty) and
hides which one, even from the person running CERT, until the end.

## Requirements

- **A MidCoast Lab** at compatibility 1.6 or later (`lab.yaml` `version`), with
  Phase 1 built: two DCs and a pipeline-built MGMT.
  - 1.6 gives the lab's Proxmox role the snapshot rights CERT uses.
    `proxmox-setup.sh` must have been re-run after the update.
  - 1.6 also makes the pipeline refuse to change the lab while a CERT run is
    open (`CERT.lock`).
- **Nowhere extra for the fixer.** By default the fixer works on MGMT. Who
  can reach MGMT by Remote Desktop, and from where, is the lab's setting
  (`network.remote_desktop_from` in `site.yaml`).
- **A lab on 1.5** works too, if the host owner adds the snapshot rights once,
  as root on a node:
  ```bash
  pveum role modify MidCoastProvisioner --append 1 --privs VM.Snapshot,VM.Snapshot.Rollback,Datastore.Audit
  ```
- **Storage for snapshots.** On the lab's LVM-thin (or ZFS) storage, a set
  costs the changes made since the snapshot, plus each VM's RAM when RAM is
  included: about 12 GB for two DCs and a W11. Thin storage that fills up stops
  every VM on it. CERT warns at 80% and allows at most 3 sets
  (`cert.config.yaml`).
- On MGMT, nothing new: PowerShell 7, git, `powershell-yaml` and the lab's
  KeePass vault are already there.

## Installing on MGMT

For a tested version, use the **latest release**: it's at the top of
[Releases](https://github.com/MidCoast-Labs/cert/releases/latest), and
each release is a tag (`v<version>`, the version CERT's menu shows). `master`
can be ahead of it. The clone below gets `master`. To install a release
instead, add `--branch v<version>` to `git clone`. Note that **Update modules**
then moves CERT on to the current `master`. To stay on releases, skip it, and
take a later release with `git fetch --tags` and `git checkout v<version>`.

As your admin account (`<you>-a`), in PowerShell 7:

```powershell
git clone https://github.com/MidCoast-Labs/cert.git C:\MidCoastLab\cert
cd C:\MidCoastLab\cert
Get-ChildItem -Recurse | Unblock-File
./tools/Test-CertModule.ps1 -LabRoot C:\MidCoastLab\repo     # every module should say OK
./Start-Cert.ps1
```

- The defaults expect the lab repo at `C:\MidCoastLab\repo`, the fixer to
  work on MGMT, and runs in `C:\MidCoastLab\cert-runs`. To change any
  of these, copy `cert.config.example.yaml` to `cert.config.yaml` and keep only
  the lines you change.
- Before the first real scenario, run **Snapshot test** from the menu. It
  snapshots the lab and rolls it back with nothing broken, which proves the
  Proxmox rights, the storage and the timings.

**The fixer on MGMT.** MGMT is the lab's Tier 0 machine and is never rolled
back. Anything the fixer changes there stays after the revert: tools they
install, files they leave, settings they change.
- The handover tells them MGMT's own settings, `C:\MidCoastLab` and the
  pipeline are out of scope.
- The pipeline won't run while a scenario is open.
- Each run's folder is readable only by the account running CERT, because
  it holds the engagement password and, in a blind run, the scenario's name.
- Look over MGMT after a run with a fixer you don't know.

**MGMT rotation:** `cert-runs\` isn't part of the lab's handover. Copy it to
the new MGMT if you want the history, and clone CERT there again. Finish or
revert any open run before you rotate MGMT.

## The control panel

`./Start-Cert.ps1` shows the lab, where the fixer works and any open run, then one of
two menus.

**No run open:**
- **Update modules.** Fetches this repo and every extra source, and lists the
  new, updated and removed modules and their commits. Nothing is taken until
  you accept it, and only as a fast-forward.
- **List modules**, with any problems.
- **Start a scenario**, or **a surprise scenario**.
- **Snapshot test.**
- **Snapshot sets**: list them and remove them.
- **Past runs** and their reports.

**A run open:**
- show the handover
- start the clock
- check the break took
- record "cause identified", or add a note
- check the repair
- show the reference solution (to the owner)
- write the report
- revert and end the run

Quitting leaves the run open; the next `Start-Cert.ps1` picks it up.

## Snapshot sets, from the Proxmox host

A host owner can see and remove CERT sets without MGMT, as root on any node:

```bash
./tools/cert-snapshots.sh list
./tools/cert-snapshots.sh remove CERT-261106-1830-00          # asks you to type the name
./tools/cert-snapshots.sh prune --older-than 14 --dry-run
```

Only snapshots named `CERT-*` on VMs tagged `midcoast-lab` or
`midcoast-lab-<site>` are touched (every lab on the cluster). Use `--tag <tag>`
for one lab only. Removing the set of a run that's still open means
that run can't be reverted: check with the lab owner first.

## Scenario modules

| Module | What breaks | Fixer gets (signs in to MGMT with it) | Difficulty |
|---|---|---|---|
| `fsmo-holder-lost` | The PDC emulator, which holds every FSMO role, is powered off and unplugged for good | domain admin | 3 |
| `dc-locator-records-deleted` | Every DC locator SRV record in `_msdcs` and the domain zone is deleted | domain admin | 2 |
| `dc-time-skew` | A DC stops syncing time and runs 17 minutes fast | domain admin | 2 |
| `sysvol-replication-disabled` | One DC's SYSVOL subscription is disabled; SYSVOL drifts | domain admin | 3 |
| `admin-passwords-changed` | Every Tier 0 admin password is reset by an "intruder", who leaves a domain admin behind | break-glass domain admin | 3 |
| `gpo-deleted` | The DCs' LAPS/DSRM GPO is deleted; last night's GPO backup is on the PDC | domain admin | 2 |

Each has a `briefing.md` (what the owner tells the fixer) and a `solution.md`
(what was done, what a fixer should find, a reference fix). Writing your own:
[docs/module-spec.md](docs/module-spec.md). Contributing:
[CONTRIBUTING.md](CONTRIBUTING.md).

**Modules from elsewhere.** Add a git repo of modules under `sources:` in
`cert.config.yaml`; *Update modules* clones it and keeps it current. A module
runs as a domain administrator on a Tier 0 machine, so add only sources you
trust, and read what changed before you take an update.

## What's where

```
Start-Cert.ps1             the control panel
cert.config.example.yaml   settings and their defaults (copy to cert.config.yaml to change)
src/Cert/                  the CERT module: lab, Proxmox, guests, catalog, runs, reports
modules/<id>/              scenario modules: module.yaml, break.ps1, verify.ps1, briefing.md, solution.md
tools/Test-CertModule.ps1  checks modules (for contributors and CI)
tools/cert-snapshots.sh    list/remove CERT snapshot sets on the Proxmox host
tests/Run-Tests.ps1        offline tests (fake Proxmox, no guests)
docs/module-spec.md        how to write a module
```
