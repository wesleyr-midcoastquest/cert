**What was broken:** first every GPO was backed up to
`C:\GPO-Backups\<date>` on the PDC emulator. Then `MidCoast-LAPS-DSRM` was
deleted with `Remove-GPO`. That also removes its link to the Domain
Controllers OU.

**What the fixer should find**
- The Domain Controllers OU no longer links `MidCoast-LAPS-DSRM`
  (`Get-GPInheritance`, or GPMC).
- `Get-GPO -All` doesn't list it.
- Event 5136/5141 (directory object deleted) in the Security log, if
  directory service changes are audited.
- The backup folder has it: `Get-GPO`-style details are in each backup's
  `bkupInfo.xml`, or use GPMC → Group Policy Objects → Manage Backups.

**Reference fix**
1. Restore the deleted GPO from the backup. In GPMC: Group Policy Objects →
   Manage Backups, pick `MidCoast-LAPS-DSRM`, Restore. With PowerShell:
   `Restore-GPO` works only on a GPO that still exists. For a deleted one use
   GPMC, or `Import-GPO -BackupGpoName MidCoast-LAPS-DSRM -Path <backup> -TargetName MidCoast-LAPS-DSRM -CreateIfNeeded`.
   That creates a new GUID, which CERT reports but doesn't fail.
2. **Link it again** to `OU=Domain Controllers`. A restore never brings links
   back: `New-GPLink -Name MidCoast-LAPS-DSRM -Target "OU=Domain Controllers,<domain DN>"`.
3. On each DC: `gpupdate /force`, then `Invoke-LapsPolicyProcessing`. Check
   that `Get-LapsADPassword -Identity <DC>` shows a fresh DSRM password update.

**The usual miss:** step 2. The GPO is back, but nothing applies it.
