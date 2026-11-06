# Security

CERT breaks a **lab** on purpose and runs as a domain administrator from its
Tier 0 management machine. Point it only at a MidCoast Lab, never at
production.

**Reporting a problem:** if you find something that could harm a lab beyond
the scenario, such as a module change the revert doesn't undo, a secret
written to disk or a log, or a way for a module source to run code without
being shown, please report it privately with GitHub's **Report a
vulnerability** (Security tab), not in a public issue.

**Module sources run as code.** Add extra sources only from people you trust,
and read what *Update modules* shows before you accept it.
