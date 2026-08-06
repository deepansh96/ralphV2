---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are already settled — the questions you can ask now without guessing at answers you have not heard yet. Ask the whole frontier in one round: number each question and give your recommended answer. Then wait for the user's answers before the next round.

If the user or repository instructions request one question at a time, honor that preference while keeping the same design tree, fact/decision split, and confirmation gate.

Each question must use this format:

```
❓ **Q1** - **<question title>**: <question body, which may include multiple choices>

➡️ <your recommended answer>
```

Each round reshapes the tree. Settled decisions push the frontier outward and unblock later questions. Recompute the frontier after every answer round. A question whose answer depends on another question still open in this round belongs to a later round.

Finding facts is your job, never the user's. When a frontier question needs a fact from the environment, use a read-only subagent if the harness supports one; otherwise look it up directly. The subagent returns facts only and must not modify files, Git, or the tracker. Do not block the whole round while it runs: only questions downstream of that fact wait. Decisions belong to the user — put each one to them and wait.

The session is done when the frontier is empty: every branch of the design tree has been visited and nothing is silently assumed. Do not act on the result until the user confirms you have reached a shared understanding.
