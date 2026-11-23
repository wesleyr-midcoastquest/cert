# Writing a scenario module

A module is a folder under `modules/` (or under a source's module path) named
after its `id`:

```
modules/<id>/
  module.yaml     what it is, what it needs, what it breaks, how to tell
  break.ps1       breaks the lab (runs on MGMT, PowerShell 7)
  verify.ps1      optional: is it really fixed? (runs on MGMT, PowerShell 7)
  briefing.md     what the impacted owner tells the fixer
  solution.md     what was done, what a fixer should find, a reference fix
```

Check it with `./tools/Test-CertModule.ps1 -Path modules/<id> -LabRoot <midcoast-labs clone>`.
CI runs the same check on every pull request.

## module.yaml

```yaml
id: gpo-deleted                 # lower case, digits, dashes; the folder's name
version: 1.0.0                  # x.y.z; raise it with every change (Update shows old -> new)
name: GPO deleted               # a title
summary: The DCs' LAPS/DSRM policy was deleted; a recent GPO backup exists on the PDC   # one menu line, 100 characters at most
category: GroupPolicy           # ActiveDirectory | DNS | GroupPolicy | Replication | Time | Identity | Other
difficulty: 2                   # 1 (routine) to 5 (hard); surprise mode can cap it
destructive: false              # true if it switches machines off or removes directory objects
authors: [Your Name]
tags: [group-policy, backup]    # free

requires:
  cert: ">=0.1"                 # oldest CERT it works with (only >= is supported)
  lab: ">=1.5"                  # oldest lab compatibility number (lab.yaml version)
  roles: { DC: 1 }              # minimum active instances per lab role
  assessor: true                # needs somewhere for the fixer to work (MGMT by default, so always met)

targets:                        # names the scripts use, and how each is chosen
  - name: dc
    select: pdc                 # pdc | non-pdc-dc | any-dc | all-dcs | assessor | role:<ROLE>

engagement:
  access: domain-admin          # domain-admin | standard | none: the account handed to the fixer
  briefing: briefing.md

exclude_from_validation: []     # targets that can't validate themselves (e.g. one switched off)
settle_seconds: 60              # wait after the break before checking it took (default 60)
expected_failures: [LAPS-002]   # lab validation IDs the break should trip

break: break.ps1
verify: verify.ps1              # optional, but a module needs expected_failures, verify, or both
solution: solution.md
```

**Selectors.**

| `select` | Picks |
|---|---|
| `pdc` | the DC holding the PDC emulator (asked of the directory, not the ledger) |
| `non-pdc-dc` | another active DC |
| `any-dc` | a random active DC |
| `all-dcs` | every active DC, as an array |
| `assessor` | the fixer's machine, if it's in the snapshot set (a W11; never MGMT) |
| `role:<ROLE>` | the first active instance of a lab role, e.g. `role:ADES` |

A target must be in the snapshot set: CERT refuses a module whose target
resolves to MGMT, or to anything else a revert can't restore.

**expected_failures** are lab validation IDs from the lab's
`platform/validation/catalog.psd1`, such as `FSMO-001` or `DNS-002`. CERT runs
the lab's validation `settle_seconds` after the break. Each listed ID it
doesn't see is reported as "not seen yet", which warns the owner that the
break may not have taken. List only failures that show within minutes:
`REPL-002`, for one, takes three hours.

## break.ps1 and verify.ps1

Both get one parameter, `$Context`:

| Property | What |
|---|---|
| `Lab` | the lab: `.Inventory` (resolved lab.yaml + site.yaml), `.Instances` (ledger), `.Site`, `.Release` |
| `Targets` | your target names → ledger instances (`.name`, `.vmid`, `.ipv4`, `.role`); `all-dcs` is an array |
| `Run` | the run record: `.id`, `.engagement.account`, ... |
| `Assessor` | where the fixer works: `.Name`, `.Address`, `.Instance`, `.IsMgmt` |
| `Config` | CERT's settings |
| `ModulePath` | your module's folder |

Helpers:

| Helper | Does |
|---|---|
| `Invoke-CertTarget -Context $Context -Instance <target> -ScriptBlock { ... } [-ArgumentList ...] [-TimeoutSeconds n]` | runs code on a lab machine, over WinRM/HTTPS as a lab domain admin. Keeps trying to connect for `-TimeoutSeconds` (default 300 in `break.ps1`, 60 elsewhere) |
| `Stop-CertTarget -Context $Context -Instance <target>` | hard power-off (pulled plug) |
| `Set-CertTargetLink -Context $Context -Instance <target> -Up $false` | unplugs the network (`$true` plugs it back) |
| `Save-CertModuleState -Context $Context -State @{...}` / `Get-CertModuleState -Context $Context` | remembers what the break did (GUIDs, times, account names), for verify |
| `New-CertCheck -Name <id> -Passed <bool> -Detail <text> [-On <machine>] [-Severity Critical\|High\|Medium\|Low]` | one verify result |
| `Get-CertPdcInstance -Lab $Context.Lab`, `Get-CertActiveInstances -Lab $Context.Lab [-Role DC]` | the lab, as the directory and the ledger see it |
| `Get-LabDomainDN`, `Get-LabTierOU`, ... | the lab's own `Lab.Inventory` functions |

**break.ps1** breaks the lab and returns a line or two saying what it did.
That text goes in the timeline, and is hidden in blind runs. If it throws,
the run stays open with the lab possibly half-broken, and the owner reverts.

**verify.ps1** returns `New-CertCheck` results. *Check the repair* combines
them with the lab's own validation. Any failed Critical or High check, from
either source, means not fixed yet. Medium and Low are reported but don't
block. `Severity` defaults to Critical. CERT also runs verify right after the
break, and expects at least one blocking check to fail then. A verify that
already passes on a broken lab checks the wrong thing.

Check the **outcome**, not the method: "every FSMO role is on a live DC", not
"ntdsutil was run". A fixer who finds another correct way should pass.

## Rules

1. **Never delete a VM or a disk.** A snapshot can't bring either back. For a
   machine that's "gone", power it off and unplug it (`Stop-CertTarget`,
   `Set-CertTargetLink`). CERT has no delete function, and modules mustn't
   add one or call the Proxmox API themselves.
2. **Break only after the snapshot, and only the set.** CERT calls
   `break.ps1` after the snapshot. Don't touch MGMT: it isn't in the snapshot,
   so nothing would undo the change.
3. **Code inside `-ScriptBlock` runs in Windows PowerShell 5.1** on the guest.
   No `??`, no ternaries, no `ForEach-Object -Parallel`. Pass values in with
   `-ArgumentList`; variables from the outer script aren't there. Give
   several values as they are: `-ArgumentList $names, $other`, where `$names`
   arrives as an array. Only a lone array needs wrapping, `-ArgumentList
   (, $names)`, or its items arrive as separate arguments. Wrapping one of
   several, `(, $names), $other`, delivers an array inside an array, which
   AD cmdlets refuse; the module check flags it.
4. **Keep CERT's way in working.** CERT reaches guests as the built-in domain
   Administrator, or `svc-labdeploy` if that fails. A module may change one of
   them, never both. The briefing should put the other out of scope, the way
   `admin-passwords-changed` does.
5. **No secrets in the repo, the module state or the output.** Passwords a
   break sets are random and thrown away. The revert brings the real ones back.
6. **Name things the lab already uses.** Read names, OUs and domains from
   `$Context.Lab.Inventory`, never a site's literal values. Modules are public
   and run on every site.
7. **Be idempotent where you can.** An owner may run the same module from the
   same snapshot many times.

## briefing.md and solution.md

**briefing.md** is what a customer would say: symptoms, what they think
changed, what they need, what's out of scope. It never says what CERT did.
Plain text, a short paragraph or three. The panel adds where to work from
(usually MGMT, with its out-of-scope note) and the account.

**solution.md** is for the owner and the report. Use bold lead-ins, not a
top-level heading (it's embedded in the report). Cover:
- what was broken
- what the fixer should find (tools, events, symptoms)
- a reference fix, in steps
- the usual wrong turns or misses
- what CERT checks
