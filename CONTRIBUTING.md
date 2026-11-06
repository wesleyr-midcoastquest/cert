# Contributing

New scenario modules are the most useful contribution. Read
[docs/module-spec.md](docs/module-spec.md) first.

1. Fork, then add `modules/<id>/`.
2. Check it: `./tools/Test-CertModule.ps1 -Path modules/<id> -LabRoot <midcoast-labs clone>`.
3. Run it against a lab of your own, at least twice from the same snapshot.
   Revert in between. Both times, check that the break shows up, that the
   reference fix passes *Check the repair*, and that the revert leaves the
   lab passing validation.
4. Open a pull request saying which lab release you tested on. CI runs the
   module check, the offline tests and shellcheck.

A change to an existing module raises its `version`. Changes to CERT itself
(`src/`, `Start-Cert.ps1`) need `tests/Run-Tests.ps1` passing, and a new test
for new behaviour.

Every module is reviewed as code that runs as a domain administrator: no
network calls outside the lab, no deleting VMs or disks, no secrets.
