## Human input

[ralph-exchange:{{EXCHANGE_ID}}]

The session stopped ({{BLOCK_REASON}}) and the human wrote this input:

{{HUMAN_INPUT}}

Open questions (JSON). Answer each of these question IDs:

{{QUESTIONS}}

Reopened decisions (JSON). Answer each of these question IDs again:

{{REOPENS}}

Settled decisions (JSON):

{{DECISIONS}}

The human input is authoritative evidence; cite this session's human-input file for answers that rely on it. You still own every decision. Give exactly one answer for each open and reopened question ID above, plus an updated answer for each settled decision the input changes. Return `needsHuman` only if the input still leaves a question undecidable.

Reply with Answers JSON only, with `"exchangeId": "{{EXCHANGE_ID}}"`.
