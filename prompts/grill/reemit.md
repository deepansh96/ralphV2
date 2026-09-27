## Re-emit

[ralph-exchange:{{EXCHANGE_ID}}]

Your reply to exchange {{EXCHANGE_ID}} was not a valid {{KIND}} message: it must be exactly one JSON object that follows the message contract, with `"exchangeId": "{{EXCHANGE_ID}}"` and every required field. Do not start over or change your decisions; re-emit your reply to exchange {{EXCHANGE_ID}} in the valid form.

This is the only re-emit request. If the reply is still invalid, the session blocks for a human.

Reply with JSON only.
