# Ralph

Ralph is an autonomous development pipeline that turns a GitHub issue into a reviewed pull request. Named after Ralph Wiggum.

## Language

### Pipeline & Execution

**Pipeline**:
The fixed sequence of steps Ralph executes for a single GitHub issue, from decision review through PR creation.
_Avoid_: workflow, job, run

**Step**:
One unit of work in the pipeline, identified by a type and executed by a single agent.
_Avoid_: task, stage, phase

**Step Type**:
The kind of work a step performs. Maps 1:1 to a prompt template in `prompts/<step-type>.md`.
_Avoid_: action, command

**Phase**:
Whether a step is part of the fixed pipeline (`fixed`) or appended dynamically by preflight (`dynamic`).
_Avoid_: tier, level

### Agents & Review

**Agent**:
An AI coding tool that executes a step. Currently `claude` (Anthropic CLI) or `codex` (OpenAI CLI).
_Avoid_: model, worker, runner

**Council**:
A multi-agent review harness that fans a prompt to multiple agents in parallel and collects their outputs. Invoked via the `council` CLI.
_Avoid_: committee, panel

**Reviewer**:
An agent participating in a council review. Each review step lists its reviewers in the `reviewers` array.
_Avoid_: evaluator, critic

### Planning

**PRD**:
Product Requirements Document. In artifact-mode runs, written into the PRD Artifact Issue by the `create-and-review-prd` step and linked from the Parent Issue Index.
_Avoid_: spec, design doc

**Slice**:
A vertical implementation unit that delivers one end-to-end behavior. Each slice becomes a GitHub sub-issue.
_Avoid_: task, ticket, chunk, horizontal layer

**Parent Issue**:
The GitHub issue that represents one Ralph pipeline run. It should stay small and act as an index to the run's artifact issues, implementation slice issues, branch, and PR.
_Avoid_: master issue, root ticket

**Artifact Issue**:
A linked GitHub sub-issue used as durable storage for one planning artifact such as decisions, the PRD, or the slice plan. Artifact issues are not implementation slices and must not become `implement-slice` steps.
_Avoid_: doc issue, fake slice, planning ticket

**Artifact Marker**:
A machine-readable marker in an artifact issue body, such as `Ralph-Artifact: decisions`, `Ralph-Artifact: prd`, or `Ralph-Artifact: slice-plan`, used alongside State to distinguish artifact issues from implementation slices.
_Avoid_: tag, magic text

**Artifact Registry**:
The top-level `artifacts` object in State that records the GitHub issue number for each artifact issue. Missing artifact issues are represented as `null` until the owning step creates or reuses them.
_Avoid_: artifact map, issue lookup table

**Parent Issue Index**:
The compact body of the Parent Issue. It links to artifact issues, implementation slice issues, the base branch, and the PR, but does not contain the full Decisions, PRD, or Slice Plan.
_Avoid_: parent body, table of contents

**Migration-on-Rerun**:
Compatibility behavior where a step initializes missing artifact state and creates or reuses artifact issues when it encounters an older workspace or parent issue that predates the Artifact Registry.
_Avoid_: global migration, upgrade script

**Artifact Source of Truth**:
The rule that each planning artifact is read from its dedicated Artifact Issue once the Artifact Registry points to it. The Parent Issue Index is only routing metadata, not the full content source.
_Avoid_: parent source, issue body source

**Artifact Provenance**:
Metadata in each Artifact Issue body that records the Parent Issue, owning Step, last updated timestamp, and the fact that Ralph may rewrite the artifact body on rerun.
_Avoid_: header, issue metadata

**Artifact Reuse**:
Idempotency behavior where Ralph reuses an existing Artifact Issue found through State or through exact `Ralph-Artifact` plus `Parent` markers instead of creating a duplicate artifact issue.
_Avoid_: dedupe, issue matching

**Artifact Closure**:
Cleanup behavior where Ralph closes Artifact Issues after the pipeline is complete, preserving them as audit history instead of deleting them.
_Avoid_: artifact deletion, cleanup delete

**Artifact Sub-Issue Link**:
The GitHub sub-issue relationship between a Parent Issue and an Artifact Issue. The markdown `Parent: #<issue>` marker is still written, but the GraphQL relationship is the primary GitHub hierarchy.
_Avoid_: artifact backlink, parent reference

**Slice Context Links**:
Compact links in an implementation Slice issue body that point back to the PRD and Slice Plan Artifact Issues while keeping the Slice self-contained for AFK work.
_Avoid_: copied context, context dump

**Runner Boundary**:
The separation where `ralph.sh` only selects steps, renders prompts, invokes agents, and records step status/metrics. GitHub artifact lifecycle behavior belongs in prompts and helper scripts, not in the runner orchestration.
_Avoid_: runner artifact logic, pipeline brain

**Artifact Helper**:
A shell helper script responsible for reusable GitHub artifact operations such as create-or-reuse, body update, sub-issue linking, parent index refresh, and artifact closure.
_Avoid_: prompt-only artifact management

**AFK**:
Autonomous mode where an agent works without human interaction until done or blocked. Slices are "AFK-ready" when an agent can complete them unattended.
_Avoid_: autonomous, unattended, headless

### State & Workspace

**Workspace**:
The per-issue directory at `workspaces/<issue-number>/` containing `state.json`, logs, and review artifacts.
_Avoid_: project, environment

**State**:
The `state.json` file tracking issue metadata, branch info, and the ordered list of steps with their statuses.
_Avoid_: config, manifest

**HITL**:
Human-in-the-loop. A step blocks for human input by writing a flag file (`hitl-<step-id>.md`) with questions. The human writes answers, then re-runs Ralph.
_Avoid_: manual review, approval gate

## Relationships

- A **Pipeline** run processes exactly one GitHub issue
- A **Pipeline** contains ordered **Steps** (fixed phase first, then dynamic phase)
- Each **Step** is executed by one **Agent**
- Review **Steps** invoke **Council** with one or more **Reviewers**
- The `create-and-review-slices` step produces **Slices**, each becoming a GitHub sub-issue
- Each **Slice** maps to one `implement-slice` **Step** (dynamic phase)
- **Artifact Issues** are linked under the **Parent Issue** but never map to `implement-slice` **Steps**
- When the **Artifact Registry** exists, the **Artifact Source of Truth** for Decisions, PRD, and Slice Plan is the corresponding **Artifact Issue**
- A **Workspace** holds the **State** and artifacts for one pipeline run

## Example dialogue

> **Dev:** "The **council** review on `create-and-review-prd` flagged a missing module. Does that block the **pipeline**?"
> **Domain expert:** "No — the **agent** running that **step** incorporates feedback and updates the **PRD** inline. It only blocks if there are open questions that need **HITL**."

> **Dev:** "Can I change which **reviewers** run on a specific **step**?"
> **Domain expert:** "Yes — edit the `reviewers` array on that **step** in **state**. The **pipeline** passes them as `--only` to **council**."

## Flagged ambiguities

- "review" can mean council review (multi-agent), code-review plugin (Claude sub-agents), or the general concept. Use **council review** or **code-review plugin** when specificity matters.
