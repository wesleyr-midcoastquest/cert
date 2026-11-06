**What was broken:** the PDC emulator, which in this lab holds all five FSMO
roles, was powered off and its network link cut. It never comes back during
the run.

**What the fixer should find**
- `netdom query fsmo` (or `Get-ADDomain` / `Get-ADForest`) names a DC that
  doesn't answer.
- `dcdiag /test:fsmocheck` fails on the survivor; `repadmin /replsummary` shows
  failures to the lost DC.

**Reference fix**
1. Seize the roles onto the survivor. Seizing is right here because the holder
   is gone for good; a transfer would need it online:
   `Move-ADDirectoryServerOperationMasterRole -Identity <survivor> -OperationMasterRole 0,1,2,3,4 -Force`
   (or `ntdsutil "roles" "connections" ... "seize ..."`).
2. Clean up the lost DC's metadata. Deleting its computer object in ADUC
   (Domain Controllers OU), with "This DC is permanently offline" ticked, does
   the full cleanup. The alternative is `ntdsutil metadata cleanup`. Then
   delete its server object from Sites and Services if it's still there.
3. Remove its DNS records: its A record, NS records in the domain and
   `_msdcs` zones, and any SRV records still pointing at it.
4. Point the survivor's DNS client at itself (loopback last, no dead
   address). Do the same on every member that used the lost DC.
5. The new PDC emulator is the domain's time source now. Give it an external
   source:
   `w32tm /config /manualpeerlist:"pool.ntp.org" /syncfromflags:manual /reliable:yes /update`,
   then `w32tm /resync`.
6. Check the survivor is a global catalog. Then check again with `dcdiag`,
   `repadmin /replsummary` and `netdom query fsmo`.

**Common misses:** the leftover DNS records, and the time source on the new PDC.
