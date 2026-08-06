---
name: grill-with-docs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's language and documented decisions.
disable-model-invocation: false
---

Run a grilling session (see [../grilling/SKILL.md](../grilling/SKILL.md)) using the domain-modeling discipline (see [../domain-modeling/SKILL.md](../domain-modeling/SKILL.md)): interview the user relentlessly about every aspect of the plan until you reach a shared understanding, updating `CONTEXT.md` and ADRs inline as decisions crystallise.

Ask the questions one at a time, waiting for feedback on each question before continuing. For each question, provide your recommended answer.

**Facts vs. decisions.** If a *fact* can be found by exploring the codebase, look it up rather than asking. The *decisions* are the user's — put each one to the user and wait for their answer. Never answer a decision on the user's behalf, even when running inside another workflow.

**Confirmation gate.** Do not write the final issue or enact the plan until the user confirms you have reached a shared understanding.

**Too big for one session?** If the effort is clearly more than one session can hold — a greenfield project, a huge multi-part feature, fog in every direction — stop and suggest charting a map with [../wayfinder/SKILL.md](../wayfinder/SKILL.md) instead. Wayfinder breaks the planning itself into decision tickets and hands each one to a session this size.

## User inputs

Before starting the grilling, ask the user for an **issue number** (optional). If the user provides an existing issue number, read it with `gh issue view <number>` and use its content as the starting point for the grilling. If no issue number is provided, a new issue will be created at the end.

## Before starting

Explore the codebase to understand the current state of the code and existing domain terminology. Follow [../domain-modeling/DOMAIN-AWARENESS.md](../domain-modeling/DOMAIN-AWARENESS.md): read `CONTEXT.md` and relevant ADRs if they exist. This grounds the grilling in what's actually built, not just what the user says.

If an existing issue was provided, read it and use it to inform your questions — challenge what's already written, identify gaps, and build on what's there rather than starting from scratch.

Many grilling questions can be answered — or at least informed — by reading the code. Before asking the user a question, check whether the codebase already has the answer. If it does, present what you found as your recommendation. If the code is ambiguous, show both what the code suggests and what's unclear, then ask.

## Branch safety

Before editing `CONTEXT.md` or ADRs, inspect the current git state:

```bash
git status --short --branch
git branch --show-current
git symbolic-ref --quiet --short refs/remotes/origin/HEAD
```

If the working tree is already dirty, stop and ask the user how to handle the existing changes before continuing. Do not mix unrelated local edits into the grilling documentation.

If the current branch is the default branch (`main`, `master`, or the branch reported by `origin/HEAD`), ask the user whether to create a planning branch before grilling changes are written. Recommend creating one unless the user says the domain documentation changes are already accepted for the default branch.

Use this naming convention:

- Existing issue: `grill/issue-<issue-number>-<slug>`
- No existing issue: `grill/<slug>`

Derive `<slug>` from the issue title or feature description: lowercase, replace non-alphanumeric runs with single hyphens, trim leading and trailing hyphens, and keep it reasonably short.

If the user agrees, create and push the planning branch before making documentation edits:

```bash
git checkout -b grill/issue-<issue-number>-<slug>
git push -u origin grill/issue-<issue-number>-<slug>
```

If the user declines because the documentation belongs on the default branch, continue on the current branch but call out that these context and ADR changes should be committed and pushed before `init`.

## During the session

Apply the domain-modeling discipline from [../domain-modeling/SKILL.md](../domain-modeling/SKILL.md) throughout:

- **Challenge against the glossary** — call out terms that conflict with `CONTEXT.md` immediately.
- **Sharpen fuzzy language** — propose a precise canonical term for vague or overloaded ones.
- **Discuss concrete scenarios** — stress-test domain relationships with edge-case scenarios.
- **Cross-reference with code** — when the user states how something works, check whether the code agrees, and surface contradictions.
- **Update `CONTEXT.md` inline** — when a term is resolved, capture it right there using [../domain-modeling/CONTEXT-FORMAT.md](../domain-modeling/CONTEXT-FORMAT.md). Don't batch these up. If no `CONTEXT.md` exists, create one as soon as the first term is resolved — an incomplete `CONTEXT.md` is far more valuable than none at all.
- **Offer ADRs with confirmation** — when a decision is hard to reverse, surprising without context, and the result of a real trade-off, ask: _"This feels like a decision worth recording as an ADR — want me to create one?"_ Use [../domain-modeling/ADR-FORMAT.md](../domain-modeling/ADR-FORMAT.md). If any of the three criteria is missing, skip the ADR. If no `docs/adr/` exists, create it when the first ADR is needed.

## Wrap-up

Once all questions are resolved, the user has confirmed shared understanding, and the grilling is complete, synthesize the resolved decisions into a GitHub issue.

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

Before ending, inspect `git status --short`. If grilling changed `CONTEXT.md` or ADRs, tell the user exactly which branch contains those changes and what must happen before Ralph `init`:

- If the changes are on a `grill/*` planning branch, commit and push them there. When ready to build from those decisions, set Ralph's `baseBranch` to that `grill/*` branch so the feature branch stacks on top of the planning docs.
- If the changes are on the default branch, commit and push them there only if the decisions are accepted independently of the feature. Then set Ralph's `baseBranch` to the default branch.
- If the user is not ready to build, leave the committed planning branch in place and do not run `init` yet.
