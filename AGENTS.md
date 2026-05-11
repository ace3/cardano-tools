# AGENTS.md

Execute complete, production-ready Cardano stake-pool decommissioning work immediately. No clarifications unless the request has direct contradictions, critical business-logic ambiguity, or unclear security constraints.

## Defaults

- Use modern, idiomatic shell/ops practices.
- Prefer simple, auditable commands over abstraction.
- Validate every chain-affecting step before submitting transactions.
- Keep changes surgical; only create or edit files required by the request.
- Do not use a git worktree unless explicitly requested.
- Never run destructive infrastructure shutdown or fund-moving commands unless the user explicitly asks for execution.

## Before Acting

- State assumptions explicitly before mutating repo files or executing chain/infra actions.
- If multiple valid interpretations exist, surface them.
- If a simpler approach exists, say so.
- If something is genuinely ambiguous and risky, ask before proceeding.

## Cardano Decommissioning Rules

- Treat mainnet transaction submission, key usage, stake deregistration, reward withdrawal, pledge movement, and infrastructure shutdown as high-risk operations.
- Pool retirement must happen before stake-key deregistration.
- Do not deregister the stake/rewards key until the 500 ADA pool deposit and remaining rewards have appeared and have been withdrawn.
- Keep the block producer, relays, and pledge in place until the selected retirement epoch starts.
- Verify the current epoch and `poolRetireMaxEpoch` before choosing a retirement epoch.
- Sign pool retirement transactions with both the payment signing key and cold signing key.
- Sign reward withdrawal and stake deregistration transactions with the payment signing key and stake signing key.
- Prefer dry-run/build/inspection steps before any submit step.
- When providing commands, make network, file paths, inputs, outputs, and required witnesses explicit.

## Execution Loop

For multi-step work, state a brief plan:

```text
1. [Step] -> verify: [check]
2. [Step] -> verify: [check]
```

Then implement, test, fix, and verify. Never present partial work as complete.

## Simplicity First

- Use the minimum code or documentation needed to solve the task.
- Do not add speculative features, broad framework scaffolding, or unused configurability.
- Match existing style when files already exist.
- If pre-existing dead code or risky residue is found, mention it instead of deleting it unless asked.

## Answers

Brevity is mandatory. If the answer fits in one sentence, use one sentence.
