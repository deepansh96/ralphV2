---
name: to-spec
description: Turn the current conversation context into a spec (you may know this document as a PRD) and submit it as a GitHub issue. Use when user wants to create a spec or PRD from the current context.
---

This skill takes the current conversation context and codebase understanding and produces a spec (you may know this document as a PRD). Do NOT interview the user — just synthesize what you already know.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Before exploring, follow [../domain-modeling/DOMAIN-AWARENESS.md](../domain-modeling/DOMAIN-AWARENESS.md). Use the project's `CONTEXT.md` vocabulary throughout the spec, and respect any ADRs in the area you're touching.

2. Sketch out the seams at which you're going to test the feature. A **seam** is the public boundary you test at: the interface where you observe behavior without reaching inside. Existing seams should be preferred to new ones. Use the highest seam possible. If new seams are needed, propose them at the highest point you can. The fewer seams across the codebase, the better — the ideal number is one.

   Working with a live user, check that these seams match their expectations. Running AFK (inside the Ralph pipeline), do not ask the user — record the chosen seams in the Testing Decisions section instead; council review judges them there.

3. Write the spec using the template below. If work started from an existing GitHub issue, update that issue with the spec content — do not create a new one. Only create a new issue if no existing issue is associated with the work. If unclear and a user is available, ask the user.

   At the top of the issue body (before the Problem Statement), include a **Decision Summary** — a concise, scannable list of every design decision made during the conversation. Each decision should be one line, stating the choice and its value (e.g. "Run ID format: `YYYYMMDD-HHmmss-<4hex>`"). This serves as a quick reference for anyone reading the spec without needing to parse the full Implementation Decisions section.

<spec-template>

## Decision Summary

A concise, scannable list of every design decision from the conversation. One line per decision, stating the choice and its value. Example:

- Auth strategy: JWT with refresh tokens, 15-min access token TTL
- Rate limiting: Per-user, 100 req/min, stored in Redis
- Pagination: Cursor-based, not offset-based
- Backward compat: V1 endpoints kept for 6 months, then removed

This section is a quick reference — the full rationale lives in Implementation Decisions below.

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.

## Testing Decisions

A list of testing decisions that were made. Include:

- The seams tests will be written at — existing seams preferred, the highest seam possible, as few as possible
- A description of what makes a good test (only test external behavior, not implementation details; expected values must come from an independent source of truth, never recomputed the way the code computes them)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this spec.

## Further Notes

Any further notes about the feature.

</spec-template>
