# Delegation contracts (inactive)

Slice #39 supplies shared helpers in `scripts/delegation.sh`. Source that file
from the project root. Bash, jq 1.6+, and Node.js 20+ are required. Run
`./tests/run.sh delegation prompt_contracts` for focused deterministic coverage;
`./tests/run.sh` also includes the delegation suite. No provider credentials are
needed for these tests.

Production does not call these helpers yet. Preflight still snapshots only the
existing model/effort fields and does not add or backfill delegation metadata.
Activation belongs to #44. Ralph remains an observer and eventual gate; the
provider's main agent owns grouping, spawning, and worker replacements.

## Schemas and safe artifacts

`delegation_validate SCHEMA` consumes exactly one JSON value on stdin, exits
nonzero on invalid input, and never echoes rejected data. Supported schemas:

- `metadata`: exactly `{"schemaVersion":1,"policy":"pr-review-v1"}` or the
  same object with policy `qa-v1`.
- `attempt`: exactly `{"id":"<opaque id>","startedAt":1787590000}` with a
  nonempty ID and nonnegative integer epoch seconds.
- `state`: validates the new fields on all steps while preserving the open
  legacy State schema. A step without metadata must not have an attempt.
- `child` / `children`: the provider-neutral record / array of records.
- `manifest`: the exact v1 artifact, including separate requested `parent` and
  `worker` settings, counts, children with `selected` or `superseded`
  disposition, evidence level, and closed mismatch vocabulary. `parentId` may
  be null only when no evidence bound a parent (see `docs/delegation-manifest.md`).
- `request` / `evidence`: the verifier input assembled by the future runner from
  State facts and one collector envelope; see `docs/delegation-manifest.md`.
- `plan`: the exact v1 QA snapshot with canonical `{id,text}` instruction
  objects and assignment objects. IDs and arrays must be unique and sorted.
- `codes`: an array using only the closed mismatch vocabulary in
  `scripts/delegation-schema.jq`.

Unknown fields are rejected throughout artifacts and nested records. Effective
child model/effort may be null; requested parent/worker settings must be present.
The Codex evidence source is `app-server`; the Claude hook source is `hooks`.
Manifest children sort by taskId, run, then childId; task IDs, checklist IDs,
assignments, and mismatch codes use lexicographic ordering. `delegation_sort_codes`
sorts and deduplicates codes. `delegation_sort_children` validates and sorts
normalized records without deleting duplicate evidence. Manifest validation
requires already sorted children and unique sorted codes.

These are structural validators, not proof of delegation. They do not assemble
manifests, compare effective settings, recompute digests, bind provider evidence,
check checklist assignment coverage, select replacement workers, or decide
completion. Manifest assembly and `pr-review-v1` verification live in
`scripts/delegation-manifest.sh` (`docs/delegation-manifest.md`); QA policy and
completion belong to later slices.
Only parsed, sanitized provider fields may be passed to these helpers; a schema
cannot determine whether an allowed string contains a secret.

`delegation_write_json WORKSPACE NAME SCHEMA` validates stdin and writes a
workspace-owned basename. It rejects path traversal and symlink/non-file
targets. It writes a same-directory exclusive temporary file, sets mode 0600,
fsyncs and closes the file, then atomically renames it. Invalid input or a failed
write preserves the old artifact and removes the temporary file. The workspace
must already exist and be owned by the pipeline; callers register resource
ownership before use. The writer is internal Node code because Bash/jq cannot
provide file fsync. State transformations remain jq operations.

## Fresh provider invocation boundary

`delegation_prepare_invocation STATE STEP PREPARE_CALLBACK` is the dormant
runner contract for the first provider invocation, every internal CLI retry,
and each manual retry or HITL resume. It:

1. Requires one matching step and validates its delegation metadata. A step
   without metadata is a byte-preserving no-op with empty stdout; the caller
   continues its existing legacy path.
2. Generates a cryptographically random UUID and epoch `startedAt`, then
   atomically saves `delegationAttempt` and `status: in_progress` in State.
3. Creates a new private `ralph-delegation-<UUID>` directory inside the workspace.
4. Calls `PREPARE_CALLBACK STATE STEP INPUT_DIRECTORY` with umask 077. The
   callback must reread current State, rerender the prompt, and create fresh
   plan/hook/log inputs only inside that directory. It must propagate errors.
5. Returns the fresh directory on stdout only after preparation succeeds.

The runner must register ownership of its attempt directories before calling
this boundary, retain its existing PID/status and retry/backoff handling, and
invoke the provider only after a successful nonempty result. It must never
reuse a cached prompt, old plan, old log, or prior attempt directory. The
callback runs in a subshell; communicate inputs through files, not shell
variable mutations. Callback stdout is redirected to stderr, so it must not
print sensitive inputs.

An unsuccessful preparation leaves the new attempt in State for audit and
returns failure without a usable directory. The caller cleans failed and
superseded temporary inputs; the final attempt stays in State after success or
failure. Existing completion updates preserve it. Collection and policy checks
must later bind evidence to that State attempt; old directories are not proof
for a new invocation. This helper does not collect evidence or launch providers.
