# Preserve native Agent sessions during automated grilling

An Automated Grilling Session uses a deterministic coordinator to relay validated, structured rounds between one Grilling Agent session and one separate Answering Agent session. A Grilling Session Record persists both providers' native session identities and resumes those exact sessions after every exchange and process restart; rebuilding either Agent from a transcript is not equivalent because it can lose provider-managed context. The Answering Agent stays read-only; the Grilling Agent may write only inside the repository, where it updates `CONTEXT.md` and ADRs inline as uncommitted changes. The Answering Agent reviews the final summary for faithfulness, and a human approves the resulting diff before the GitHub issue is created or updated; rejected documentation changes are discarded with Git.

## Considered Options

- Recreate Agents from the saved transcript on each round. Rejected because replay does not preserve the native session required by the feature.
- Let one Agent spawn and control the other. Rejected because session recovery would depend on model behavior instead of deterministic state.
- Keep both Agents read-only and have the coordinator apply staged documentation after approval. Rejected because Git already provides the preview and undo, and inline edits match human grilling.

## Consequences

Each supported Agent needs a session adapter that can start a persisted session, capture its native identity, and resume it explicitly. An Agent without those capabilities cannot participate in an Automated Grilling Session. If either native session is lost, the Automated Grilling Session fails instead of replaying its transcript or changing Agents. One session lock prevents concurrent resumes; completed records are archived locally so the native identities, exchanges, and provider logs remain auditable until explicitly cleaned up.
