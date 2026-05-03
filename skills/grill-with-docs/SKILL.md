---
name: grill-with-docs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's language and documented decisions.
disable-model-invocation: false
---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing.

## User inputs

Before starting the grilling, ask the user for an **issue number** (optional). If the user provides an existing issue number, read it with `gh issue view <number>` and use its content as the starting point for the grilling. If no issue number is provided, a new issue will be created at the end.

## Before starting

Explore the codebase to understand the current state of the code and existing domain terminology. Read `CONTEXT.md` and relevant ADRs if they exist. This grounds the grilling in what's actually built, not just what the user says.

If an existing issue was provided, read it and use it to inform your questions — challenge what's already written, identify gaps, and build on what's there rather than starting from scratch.

Many grilling questions can be answered — or at least informed — by reading the code. Before asking the user a question, check whether the codebase already has the answer. If it does, present what you found as your recommendation. If the code is ambiguous, show both what the code suggests and what's unclear, then ask.

## Domain awareness

During codebase exploration, also look for existing documentation:

### File structure

Most repos have a single context:

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

If a `CONTEXT-MAP.md` exists at the root, the repo has multiple contexts. The map points to where each one lives:

```
/
├── CONTEXT-MAP.md
├── docs/
│   └── adr/                          ← system-wide decisions
├── src/
│   ├── ordering/
│   │   ├── CONTEXT.md
│   │   └── docs/adr/                 ← context-specific decisions
│   └── billing/
│       ├── CONTEXT.md
│       └── docs/adr/
```

**If no `CONTEXT.md` exists, create one by the end of the session.** Even if it's incomplete — that's fine. Context is built up incrementally across sessions. Create it as soon as the first term is resolved, and keep adding to it as the grilling progresses. An incomplete `CONTEXT.md` is far more valuable than none at all.

If no `docs/adr/` exists, create it when the first ADR is needed.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `CONTEXT.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update CONTEXT.md inline

When a term is resolved, update `CONTEXT.md` right there. Don't batch these up — capture them as they happen. Use the format in [CONTEXT-FORMAT.md](../domain/CONTEXT-FORMAT.md).

Don't couple `CONTEXT.md` to implementation details. Only include terms that are meaningful to domain experts.

### Offer ADRs with confirmation

When a decision surfaces that meets all three criteria below, **ask the user before creating the ADR** — don't create it silently:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. If all three are true, ask: _"This feels like a decision worth recording as an ADR — want me to create one?"_ Use the format in [ADR-FORMAT.md](../domain/ADR-FORMAT.md).

## Wrap-up

Once all questions are resolved and the grilling is complete, synthesize the resolved decisions into a GitHub issue.

The issue body must include:

- A clear summary of the feature
- Decisions made during grilling (with rationale)
- Scope boundaries — what's in and what's explicitly out
- Acceptance criteria

**If an existing issue was provided**, update it:

```bash
gh issue edit <number> --title "<title>" --body-file <temp-file>
```

**If no existing issue was provided**, create a new one:

```bash
gh issue create --title "<title>" --body-file <temp-file>
```

Print the issue number and URL at the end — the user needs it to run `init`.
