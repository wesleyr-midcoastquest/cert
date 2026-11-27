We want to know whether our account reporting tool tells the truth. We've set
up a pool of test accounts in one OU, `PasswordPool` under our standard-users
OU, in a mix of states: some locked out, some with expired passwords, some
that must change their password at next logon, some that have never signed
in. We know exactly which is which.

Run the tool against the domain with the account we're giving you (it's a
domain admin), and give us its report on the pool: for each account, whether
it's locked out, whether the password has expired or must be changed, when it
expires, which password policy applies, and when it last signed in.

Please don't change the accounts: we compare your report with what we set up.
Everything outside the pool OU is out of scope.
