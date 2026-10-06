---
name: Contract
about: The plan for a feature or a change to what Kvotar is meant to do, agreed before any code
---

<!-- The maintainer approves a contract by adding the `agreed` label. Work starts after that.
     Which changes need a contract: CONTRIBUTING.md, "Which path". -->

**Goal**
One short paragraph: the problem as a user or the maintainer sees it, and what changes.

**Contract**
Numbered items. Each says exactly what changes, where, and what the result must be. Name the spec
pages in `docs/spec/` that change and what each must say afterwards. Exact copy goes here word for
word.

**Proof**
Numbered checks that show the contract holds: the tests added or changed, `make test`, `make check`,
and any synthetic reproduction or screenshot. Fixtures only. Name any live check, and who runs it.

**Deliberately untouched**
What a reader might expect this to change, and does not.

**Safety rules (optional)**
Which safety rule in [AGENTS.md](https://github.com/vladamarkov/kvotar/blob/main/AGENTS.md) the change touches, and why it does not break it.
