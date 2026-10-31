---
name: jira-dod
description: Use when working a Jira ticket (DEVOPS-xxxxx or similar) end to end, including sessions launched to "处理这个 jira", and when asked "还有什么要做 / 能结单吗 / 清理一下". Defines start-up, MR gate, acceptance and close-out so the user does not have to prompt each step.
---

# Jira definition of done

Run these steps without waiting to be asked. Stop only at the listed decision points.

## Start
1. Read the ticket with comments, its parent Epic and any linked reference ticket (credentials: `CLAUDE.md` table).
2. Read `/workspaces/.claude/knowledge/INDEX.md` when it exists. If the ticket has an Epic, read `/workspaces/.claude/epics/<EPIC>.md` when it exists.
3. If `/workspaces/.claude/handoff/<JIRA>.md` exists, resume from it.
4. Branch from `origin/<target>`. Confirm scope and plan with the user only when the ticket is ambiguous or contradicts itself.

## While working
- **Handoff file:** keep `/workspaces/.claude/handoff/<JIRA>.md` current with goal, decisions, MR links, environment, next step. Update it at each stage change; it is what survives compaction and a new session.
- **Epic notes:** record any finding a sibling ticket would hit in `/workspaces/.claude/epics/<EPIC>.md`, and read that file again before acceptance.
- **Status card (Discord):** send one message listing MRs and pipeline links, current step and blockers, then update it with `edit_message`. Send a new reply only for an outcome or a decision, because edits do not ping. Include links unprompted.
- **Testing order:** connect from the Mac to the test cluster and get it passing there, then push and let the pipeline run.
- **Tunables:** timeouts and similar values come from environment variables with defaults, so the next change needs no code edit.
- **Docs:** write English only; Chinese is generated automatically.
- **Wrong direction:** when an approach fails or the user rejects it, record the conclusion in the handoff file and restart from it instead of stacking fixes. In a terminal session, suggest `/rewind`.

## After opening or updating an MR
1. Start `pr-watch <mr-url>` as a background command and let its exit wake you. Do not poll with `ScheduleWakeup` or `Monitor` as well. Re-arm it after handling each event, except after exit code 4 (MR merged or closed). For a quick look use `pr-watch <mr-url> --once`.
2. On a failure, find the cause in a subagent and keep only the conclusion in the main thread.
3. After each significant change, review the diff in a fresh subagent that gets the diff and the ticket but not your reasoning, then post the result as an MR comment. Assess each review comment on merit, fix the valid ones and say why for the rest.
4. Merge only when the launch prompt or the user authorised it for this MR. `pr-watch` also reports a merge done by the user; continue to the next step without being told.

## Acceptance
- Install the merged or MR build with `violet package/push`, the full path a user takes. A hand-patched image does not count.
- For a template or UI change, run the form through Playwright, covering every exposure mode the ticket touches (e.g. Ingress and Gateway).
- For new documentation, follow it step by step as a user, using nothing outside it.
- Then list the remaining test gaps and whether the ticket can close, without waiting to be asked. Known limits go in the list explicitly.

## Close-out
Do all of these, then report what changed:
1. Jira: MR links in the output field, change summary and test results as a comment, required fields and status.
2. Test environment: delete instances you created, keeping one demo instance if the user is still reviewing.
3. Devpod and Mac: remove the ticket's worktree (keep the branch), temporary files and handoff file.
4. Session: remove the Discord binding through `discord:launch` when the user asks to close the session.

## Ask the user only for
Scope changes, merge or tag without prior authorisation, actions on shared/edge/idp clusters, and anything customer-facing. Bring a recommendation.

## Gotchas
Recurring failures from past tickets. Add to this list when one repeats.
- A file `violet push` can exit 0 without pushing images; check the images really arrived (see the shared knowledge folder).
- Test with the template's real rendering path. A sibling ticket's Ingress form failed to render only under Playwright.
- A green pipeline on the MR says nothing about the merged build. Re-check after merge before installing.
- Don't report that nothing exists from an empty kubectl result without checking the exit code.
- Pick the base image and registry the repo already uses; don't introduce a proxy host found elsewhere.
