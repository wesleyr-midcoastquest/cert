**What was broken:**
- The built-in Administrator and every Tier 0 `-a` account from `site.yaml`
  were reset to random passwords that nobody kept.
- `svc-sqlbackup` was created in the default `CN=Users` container, described
  as "SQL backup service", and added to Domain Admins.
- All of it was done remotely from MGMT's address (WinRM), signed in as the
  built-in Administrator. The intruder's session reset that account too, so
  the logs show Administrator as the actor.

**What the fixer should find**
- Security log on the DCs: 4724 (an attempt to reset a password) for each
  account, 4720 (account created) and 4728 (member added to a global security
  group) for `svc-sqlbackup`. Each event names the subject account
  (Administrator), and 4624 logons show where it came from (MGMT's address).
- `Get-ADUser -Filter * -Properties pwdLastSet` sorted by `pwdLastSet` shows
  the burst of resets. `Get-ADGroupMember 'Domain Admins' -Recursive` shows
  the newcomer. `whenCreated` dates it.

**Reference response**
1. Contain first: disable `svc-sqlbackup` and remove it from Domain Admins.
   Delete it only after its details are noted.
2. Treat the source as compromised. The changes came from MGMT's address. In
   a real incident you would isolate that machine. Here it's out of scope, as
   the briefing says: CERT runs from it, and the fixer works on it.
3. Reset each affected admin account to a new password, and make sure it's
   enabled and not locked. Give the passwords to their owners out of band.
4. For a real incident, also: reset `krbtgt` twice, with replication in
   between; review GPOs, AdminSDHolder, delegations and scheduled tasks for
   persistence; and rotate secrets the intruder could have read.
5. Write down the timeline: first reset, account creation, group change,
   source address.

**Not reset:** `svc-labdeploy`, the engagement account, and the admin account
running CERT (from 1.0.3; resetting it locked the person running the scenario
out of MGMT).

**Keep `svc-labdeploy` working.** CERT checks the repair with it, and the briefing
puts it out of scope. If a fixer disables it anyway, the repair check can't
reach the DCs: revert, and note it in the report.

**Checked by CERT:**
- every affected account has had its password reset since the incident and
  can sign in (enabled, not locked)
- the intruder's account is gone, or disabled and in no privileged group
- no other new Domain Admins
