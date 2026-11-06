**What was broken:** on the DC that isn't the PDC emulator, w32time was set
to `NoSync` (`/syncfromflags:NO`) and the clock moved 17 minutes ahead.
Kerberos tolerates 5 minutes, so tickets from or for that DC fail, and so
does its replication (error 1398, "There is a time and/or date difference").

**What the fixer should find**
- `w32tm /monitor` or `w32tm /stripchart /computer:<pdc>` shows the offset.
- `w32tm /query /source` on the victim says `Local CMOS Clock`.
- `w32tm /query /configuration` shows `Type: NoSync`.
- `repadmin /showrepl` shows 1398 errors. Event 4 / 1398 entries appear in
  System and Directory Service logs; Kerberos event 4 shows up on clients.

**Reference fix**
1. On the victim: `w32tm /config /syncfromflags:domhier /update`. This sets
   Type back to NT5DS.
2. Restart w32time (`net stop w32time && net start w32time`).
3. Run `w32tm /resync /rediscover`. A 17-minute step is within the default
   limit for a DC (MaxPos/NegPhaseCorrection is 48 hours on DCs), so it's
   corrected at once.
4. Purge cached tickets where needed (`klist purge`, and
   `klist -li 0x3e7 purge` for the computer's own tickets).
5. Force replication: `repadmin /syncall /AdeP`. Then check that
   `repadmin /replsummary` is clean.

**Worth asking about afterwards:** whether the PDC emulator has a real
external source (it should), and whether the hypervisor's time sync is off
for DCs.
