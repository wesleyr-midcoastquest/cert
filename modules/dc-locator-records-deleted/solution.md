**What was broken:** every SRV record was deleted from the `_msdcs.<domain>`
zone, along with the domain zone's `_tcp`, `_udp` and `_sites` locator
records. The DCs and their A records were left alone.

**What the fixer should find**
- `nltest /dsgetdc:<domain>` fails.
- `Resolve-DnsName _ldap._tcp.dc._msdcs.<domain> -Type SRV` returns nothing.
- `dcdiag /test:dns /v`, or `dcdiag /test:registerindns /dnsdomain:<domain>`,
  reports the missing records.
- On a DC, `%SystemRoot%\System32\config\netlogon.dns` lists what each DC
  should have registered.

**Reference fix**
1. On each DC, have Netlogon register its records again: `nltest /dsregdns`,
   or `Restart-Service Netlogon`.
2. Force replication (`repadmin /syncall /AdeP`), or wait a few minutes. Then
   check from each DC and from a member:
   - `nltest /dsgetdc:<domain> /force`
   - the `_ldap`, `_kerberos`, `_gc` and `pdc` SRV records
3. Members cache negative answers: `ipconfig /flushdns` on them, or wait.

**Worth asking about afterwards:** who has rights to change the `_msdcs` zone,
and whether DNS changes are audited. DNS Server audit events 516, 517 and 519
in *Microsoft-Windows-DNSServer/Audit* show who deleted what.
