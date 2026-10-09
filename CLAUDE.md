# CLAUDE.md

Read `AGENTS.md` in the repository root for operating instructions before doing anything else in this
repository. It is imported here so Claude Code always loads it:

@AGENTS.md

Sources of truth, in reading order:

1. `AGENTS.md`: how to work in this repository (rules, commands, safety gates).
2. `SPEC.md`: the authoritative project contract: what PreFlightCheck is, how it runs, and what it must
   guarantee. Read the relevant sections before changing behavior.
3. `docs/architecture.mdx`: how the current implementation meets the contract, in detail.
4. The source files and tests the task touches.

Source and tests show what the code does today. When they disagree with `SPEC.md` or
`docs/architecture.mdx`, report the mismatch instead of silently changing either side.
`.claude/CLAUDE.md` adds local environment and testing notes; if it ever conflicts with `AGENTS.md`,
`AGENTS.md` wins.
