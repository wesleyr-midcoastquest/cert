**What was built:**
- An OU `PasswordPool` under the lab's standard-users OU (`placement.standard_users`),
  holding the pool users and one pool group per tier.
- One fine-grained password policy (PSO) per tier, each applied to its pool
  group only. Every user is in exactly one pool group, so exactly one pool PSO
  applies. The Default Domain Policy is not changed.
  - `PSO-LAB-PwPool-Exp3`, `-Exp30`, `-Exp180`: normal users, password expires
    3, 30 or 180 days after it was set.
  - `PSO-LAB-PwPool-Expired`: expired users, with the smallest maximum age a
    PSO accepted (the build tries 1 minute, 5 minutes, 1 hour, then 1 day; the
    timeline says which it got).
  - `PSO-LAB-PwPool-Base`: must-change and never-expires users (365 days).
  - Every pool PSO: lockout after 3 bad passwords in 30 minutes, locked until
    an administrator unlocks (`msDS-LockoutDuration` "forever"), or 99999
    minutes if a PSO refuses that (the timeline says which).
- Users, one password state each:
  - **normal**: password set now, expires in the future;
  - **expired**: past the Expired PSO's maximum age (`PasswordExpired` true,
    `pwdLastSet` is a real date, not 0). If that age is a day, they show
    "expires at" until then: re-read (menu 3) after that time;
  - **must change**: `pwdLastSet = 0` ("User must change password at next
    logon"); AD also reports these as `PasswordExpired`;
  - **never expires** (option `never_expires_percent`, default 0).
- Independently: **locked out** by real bad-password binds against the PDC
  emulator, after group membership was in place; **cannot change password**
  (option `cannot_change_percent`, default 0; never a must-change user).
- Counts are assigned, not rolled: each state's share of the total, rounded
  half up, and normal users take the rest. 50 users at the defaults: 5 locked,
  8 expired, 8 must change, 34 normal.
- Passwords are random per user and were never written anywhere.

**The answer key:** `password-pool.csv` in the run folder, written by every
read-back, one row per pool user: planned state, password expires (date,
Never, or Must change now), `PasswordExpired`, `ChangePasswordAtLogon`,
`PasswordNeverExpires`, `CannotChangePassword`, `LockedOut`, resultant PSO,
last logon, password last set. Times are UTC.

**Dates (option C, real logons only):** about half the users who can sign in
(everyone but must-change) got one real logon, a successful bind on the PDC
right after their password was set, so `lastLogon` and `LastLogonDate` are
real and password-last-set is never after last logon. The rest have never
signed in. No dates in the past were faked:
- `lastLogonTimestamp` (behind `LastLogonDate`) is owned by the system: an
  LDAP write is refused.
- `lastLogon` isn't replicated and is set by each DC on each logon.
- `pwdLastSet` takes only `0` (must change) or `-1` (now).
The attribute test that confirms this on the lab's DCs (`Set-ADUser -Replace`
on each, and the errors) still has to be run and recorded here:

```powershell
$u = '<a pool user>'
foreach ($a in 'lastLogon', 'lastLogonTimestamp', 'pwdLastSet') {
    try { Set-ADUser $u -Replace @{ $a = (Get-Date).AddDays(-100).ToFileTimeUtc() }; "${a}: accepted" }
    catch { "${a}: $($_.Exception.Message)" }
}
```

**How each state shows in AD:**
- `Search-ADAccount -LockedOut`, `-PasswordExpired`, `-AccountInactive`,
  `-PasswordNeverExpires` with `-SearchBase` the pool OU. Lockouts are counted
  on the PDC emulator; ask it (`-Server`), as another DC may show them late.
- `Get-ADUser -Properties LockedOut, PasswordExpired, pwdLastSet,
  msDS-UserPasswordExpiryTimeComputed, msDS-ResultantPSO, LastLogonDate`.
  `msDS-UserPasswordExpiryTimeComputed` is 0 for must-change, `0x7FFFFFFFFFFFFFFF`
  for never expires, otherwise the expiry as a file time.
- `Get-ADUserResultantPasswordPolicy`, and ADUC (Advanced Features, Attribute
  Editor; the Account tab shows "Unlock account").
- Event 4740 on the PDC for each lockout.

**What a tool commonly gets wrong:**
- Reading the Default Domain Policy's maximum age instead of the resultant
  PSO, so every expiry date is off.
- Counting must-change users as expired (both have `PasswordExpired` true),
  or missing expired users whose `pwdLastSet` isn't 0.
- Reading `LockedOut` or `lastLogon` from a DC other than the PDC.
- Treating `LastLogonDate` as exact: it can lag by up to 14 days.

**What CERT checks** (the read-back; every check is Medium, a mismatch is a
warning): the planned users are all there; normal, must-change, expired,
never-expires, locked-out and cannot-change users each match the plan exactly;
each user's resultant PSO is its own tier's; and the CSV was written.
