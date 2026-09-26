## Frontier round {{ROUND}}: updated decisions

[ralph-exchange:{{EXCHANGE_ID}}]

A human sent input to the Answering Agent, which updated these decisions (JSON):

{{ANSWERS}}

These answers replace any earlier answer for the same question ID. Merge them into your design tree and update `CONTEXT.md` and `docs/adr/` inline where they change a settled term or ADR-worthy decision. Then send Frontier round {{ROUND}}: follow-up questions the updates open, a `reopens` entry for any settled decision they contradict, or an empty `questions` array and an empty `reopens` array when nothing is left to decide.

Reply with Frontier JSON only, with `"exchangeId": "{{EXCHANGE_ID}}"` and `"round": {{ROUND}}`.
