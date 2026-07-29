# Domain Docs

This repository uses a single-context domain documentation layout.

## Before exploring

Read these files when they exist:

- `CONTEXT.md` at the repository root.
- ADRs under `docs/adr/` that affect the area being changed.

If these files do not exist, proceed silently. Domain-modeling workflows create
them when terminology or architectural decisions are actually resolved.

## Layout

```text
/
|-- CONTEXT.md
|-- docs/
|   `-- adr/
`-- src/
```

## Vocabulary

Use domain terms as defined in `CONTEXT.md` in issue titles, specifications,
tests, implementation plans, and code. Avoid introducing synonyms that conflict
with the glossary.

If a required concept is missing, reconsider whether it is repository language
or record the gap for a domain-modeling task.

## ADR conflicts

If proposed work contradicts an ADR, state the conflict explicitly rather than
silently overriding the decision. Include the ADR identifier and the reason the
decision may need to be revisited.
