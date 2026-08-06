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
An AI coding tool that executes a step. Currently `claude` (Anthropic CLI), `codex` (OpenAI CLI), or `deepseek` (DeepSeek through Pi).
_Avoid_: model, worker, runner

**Council**:
A multi-agent review harness that fans a prompt to multiple agents in parallel and collects their outputs. Invoked via the `council` CLI.
_Avoid_: committee, panel

**Reviewer**:
An agent participating in a council review. Each review step lists its reviewers in the `reviewers` array.
_Avoid_: evaluator, critic

**Review Axis**:
One independent perspective applied to a PR by the multi-axis review step. Each axis is defined by one bundled review skill.
_Avoid_: council member, review round

### Local QA

**Local QA Checklist**:
A PR comment containing manual behavior checks that can be executed entirely on the local machine with external boundaries stubbed.
_Avoid_: test plan, deployed QA

**Local Resource**:
A process, container, browser session, computer-use session, temporary file, or worktree change created by a pipeline step and owned by that pipeline.
_Avoid_: arbitrary local process, user file

**Always-Run Step**:
A cleanup step that Ralph executes after normal completion or after another step fails.
_Avoid_: finally block, post-merge cleanup

### Planning

**PRD**:
Product Requirements Document. Written into the parent GitHub issue body by the `create-and-review-prd` step. The bundled `to-spec` skill calls this document a spec; inside Ralph, PRD is the canonical term.
_Avoid_: design doc; "spec" outside the skill name

**Slice**:
A vertical implementation unit that delivers one end-to-end behavior. Each slice becomes a GitHub sub-issue. The bundled `to-tickets` skill calls these tickets; inside Ralph, slice is the canonical term.
_Avoid_: task, chunk, horizontal layer; "ticket" outside the skill name and wayfinder

**Seam**:
The public boundary a test observes behavior at. Seams are pre-agreed in the PRD's Testing Decisions; implement-slice writes tests only at those seams.
_Avoid_: test point, hook

**Blocking Edge**:
A declared dependency between slices: the blocker must close before the blocked slice starts. Represented both as a native GitHub issue dependency and a `Blocked by: #<n>` body line.
_Avoid_: ordering hint, soft dependency

**AFK**:
Autonomous mode where an agent works without human interaction until done or blocked. Slices are "AFK-ready" when an agent can complete them unattended.
_Avoid_: autonomous, unattended, headless

### Wayfinding

**Map**:
A single GitHub issue (label `wayfinder:map`) charting an effort too big for one session: destination, decisions so far, fog, and out-of-scope, with child Decision Ticket issues. Produced and worked by the `wayfinder` skill; never enters the pipeline itself.
_Avoid_: plan doc, tracker board

**Decision Ticket**:
A child issue on a wayfinder Map whose resolution is a decision, not a Slice or another unit of implementation. Its type is research, prototype, grilling, or task; it closes before Ralph build planning begins.
_Avoid_: implementation ticket, slice, work item

**Frontier**:
The Map's open, unblocked, unclaimed Decision Tickets — what a session can take next.
_Avoid_: backlog, queue

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
- Council review **Steps** invoke **Council** with one or more **Reviewers**
- The `create-and-review-slices` step produces **Slices**, each becoming a GitHub sub-issue with its **Blocking Edges**
- Each **Slice** maps to one `implement-slice` **Step** in the dynamic phase
- The post-implementation **Steps** check the branch, create the PR, prepare and execute the **Local QA Checklist**, and run four **Review Axes**
- `cleanup-local-resources` is an **Always-Run Step** created during init and
  deferred until normal work ends; it removes pipeline-owned **Local Resources**
- A wayfinder **Map**'s destination issue is what `init` consumes; `create-and-review-prd` performs the `to-spec` handoff, while the **Map** itself stays outside the **Pipeline**
- A **Workspace** holds the **State** and artifacts for one pipeline run

## Example dialogue

> **Dev:** "The **council** review on `create-and-review-prd` flagged a missing module. Does that block the **pipeline**?"
> **Domain expert:** "No — the **agent** running that **step** incorporates feedback and updates the **PRD** inline. It only blocks if there are open questions that need **HITL**."

> **Dev:** "Can I change which **reviewers** run on a specific **step**?"
> **Domain expert:** "Yes — edit the `reviewers` array on that **step** in **state**. The **pipeline** passes them as `--only` to **council**."

## Flagged ambiguities

- "review" can mean council review, one **Review Axis**, the consolidated multi-axis PR review, or the general concept. Name the specific review when it matters.
