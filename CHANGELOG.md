# Changelog

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
