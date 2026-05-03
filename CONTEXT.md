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
Product Requirements Document. Written into the parent GitHub issue body by the `create-and-review-prd` step.
_Avoid_: spec, design doc

**Slice**:
A vertical implementation unit that delivers one end-to-end behavior. Each slice becomes a GitHub sub-issue.
_Avoid_: task, ticket, chunk, horizontal layer

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
- A **Workspace** holds the **State** and artifacts for one pipeline run

## Example dialogue

> **Dev:** "The **council** review on `create-and-review-prd` flagged a missing module. Does that block the **pipeline**?"
> **Domain expert:** "No — the **agent** running that **step** incorporates feedback and updates the **PRD** inline. It only blocks if there are open questions that need **HITL**."

> **Dev:** "Can I change which **reviewers** run on a specific **step**?"
> **Domain expert:** "Yes — edit the `reviewers` array on that **step** in **state**. The **pipeline** passes them as `--only` to **council**."

## Flagged ambiguities

- "review" can mean council review (multi-agent), code-review plugin (Claude sub-agents), or the general concept. Use **council review** or **code-review plugin** when specificity matters.
