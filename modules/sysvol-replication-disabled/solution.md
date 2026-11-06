**What was broken:** on the DC that isn't the PDC emulator, `msDFSR-Enabled`
was set to FALSE on its SYSVOL subscription object:
`CN=SYSVOL Subscription,CN=Domain System Volume,CN=DFSR-LocalSettings,CN=<DC>,OU=Domain Controllers,...`

DFSR then stopped replicating SYSVOL there (DFS Replication event 4114). After
that, `logon-notice.txt` was changed on the PDC, so the two SYSVOLs differ.

**What the fixer should find**
- `dfsrdiag replicationstate`, or the backlog
  (`dfsrdiag backlog /rgname:"Domain System Volume" /rfname:"SYSVOL Share" /smem:<pdc> /rmem:<victim>`).
- `Get-DfsrState`, or `DfsrReplicatedFolderInfo` in WMI, shows the folder isn't in state 4.
- DFS Replication event 4114 on the victim.
- `dcdiag /test:sysvolcheck /test:dfsrevent`.
- The file differs between `\\<pdc>\NETLOGON` and `\\<victim>\NETLOGON`.

**Reference fix** (the second half of a non-authoritative SYSVOL sync)
1. Set `msDFSR-Enabled` back to TRUE on the victim's SYSVOL subscription
   (ADSI Edit, or `Set-ADObject ... -Replace @{'msDFSR-Enabled'=$true}`).
   Make sure it replicates to both DCs: `repadmin /syncall /AdeP`.
2. On the victim, run `dfsrdiag pollad`. Wait for DFS Replication event 4614,
   then 4604 ("SYSVOL has been initialized"). The victim takes its SYSVOL from
   its partner.
3. Check: the file matches on both DCs, `Get-DfsrState` is clean, and
   `SysvolReady` is 1.

**Wrong turns:**
- An *authoritative* restore (setting `msDFSR-Options=1` on the PDC) isn't
  needed here. It would also overwrite any change made only on the victim.
- Copying files into SYSVOL by hand fixes nothing: DFSR is still off.
