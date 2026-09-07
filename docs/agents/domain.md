# Domain docs

These rules tell engineering skills how to read this repository's domain documentation.

## Before exploring

Read the files that exist and relate to the work:

- `CONTEXT.md` at the repository root
- `docs/adr/` entries that cover the area being changed

If these files do not exist, continue without calling out their absence. The `/domain-modeling` skill creates them when the project resolves terms or architectural decisions.

## File structure

Nearfield uses a single-context layout:

```text
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-example-decision.md
│   └── 0002-another-decision.md
├── Sources/
└── Tests/
```

## Use the glossary's vocabulary

When an issue title, proposal, hypothesis, or test names a domain concept, use the term defined in `CONTEXT.md`. Do not replace it with synonyms the glossary rejects.

If a needed concept is missing, reconsider whether the term belongs in the project. If it does, note the gap for `/domain-modeling`.

## Flag ADR conflicts

If proposed work contradicts an existing ADR, say so instead of silently overriding the decision. Name the ADR and explain why it may need reconsideration.
