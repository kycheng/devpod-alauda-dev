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
- **Waiting on the user:** any message that waits for the user to merge, review or decide ends with a `待你处理` list, one item per line with its link (MR, pipeline, Jira, report). The user asked "PR 发我" about 25 times in one month because this was missing.
- **Temp files:** when you create files on the Mac or outside the scratchpad (test dirs, downloaded packages, scripts), list them under `## Temp files` in the handoff file as `- mac:/tmp/x` or `- /tmp/y`. `session-close` deletes that list (paths outside `/tmp` and the Mac temp dirs, or with glob/shell characters, are skipped and printed), plus the cwd's scratchpad.
- **Testing order:** connect from the Mac to the test cluster and get it passing there, then push and let the pipeline run.
- **Tunables:** timeouts and similar values come from environment variables with defaults, so the next change needs no code edit.
- **Docs:** write English only; Chinese is generated automatically.
- **Wrong direction:** when an approach fails or the user rejects it, record the conclusion in the handoff file and restart from it instead of stacking fixes. In a terminal session, suggest `/rewind`.

## After opening or updating an MR
1. **Jira Output URL, right away:** as soon as an MR/PR linked to a Jira ticket is opened, append its URL to the ticket's `Output URL` field (`customfield_12406`, plain string, one URL per line). Read the current value first and keep the existing URLs; skip a URL already there. Do this when the MR is created, not at close-out. Basic auth from the `CLAUDE.md` credentials table, e.g. `PUT /rest/api/2/issue/<JIRA>` with `{"fields":{"customfield_12406":"<old>\n<new>"}}`, then GET it back to check. Note it in the handoff file.
2. Start **one** `pr-watch <mr-url> [<mr-url>...]` as a background command with every MR the session is waiting on, and let its exit wake you. Do not run one watcher per MR, and do not poll with `ScheduleWakeup` or `Monitor` as well. Keep the default 24h timeout. Re-arm it after handling each event, except after exit code 4 (every MR merged or closed); an MR that is merged with nothing new is dropped and the rest keep being watched. A timeout (exit 2) with nothing new: re-arm without sending a Discord reply. Put `<!-- claude -->` in MR comments you post so they don't wake you. For a quick look use `pr-watch <url>... --once`.
3. On a failure, find the cause in a subagent and keep only the conclusion in the main thread.
4. **Review and fix loop:** after opening the MR and after each significant change, review the diff in a fresh subagent that gets the diff and the ticket but not your reasoning. The same applies to review comments left by people or bots.
   - Verify each finding against the code before acting (`superpowers:receiving-code-review`).
   - A finding that is a clear problem (bug, regression, security issue, broken test, missing error handling, wrong behaviour vs. the ticket): fix it directly without asking, push, and re-run the review on the new diff. Repeat until no clear problem is left.
   - Leave as a question for the user only what changes scope or is a matter of preference; say why it was not fixed.
   - **Post the outcome on the MR** as a comment (reply in the thread for an existing review comment): for each finding, what it was, whether it was valid, what was changed with the commit SHA, and how the fix was verified (test, command, pipeline). For findings not fixed, give the reason. One summary comment per review round.
5. Merge only when the launch prompt or the user authorised it for this MR. `pr-watch` also reports a merge done by the user; continue to the next step without being told.

## Long waits
When the only work left is waiting hours or days (stability or HA test runs, a release-test env, an external review):
- One watcher per kind of wait, written to exit only on a terminal state, with a timeout at least as long as the expected run. Never a loop that prints progress.
- A wake-up with nothing to act on: re-arm and end the turn, without a reply.
- Subagents do not start background waits. Tell them to block in the foreground with a timeout or to return; their "waiting on its own background work" notices wake the main thread for nothing.
- If the session is more than about a week old and is only waiting, update the handoff file, tell the user, and offer to restart it from the handoff (`discord:launch stop` then `start` on the same cwd keeps the thread). Each wake-up of an old session re-reads ~250k tokens; a fresh one starts at ~50k.

## Acceptance
- Install the merged or MR build with `violet package/push`, the full path a user takes. A hand-patched image does not count.
- For a template or UI change, run the form through Playwright, covering every exposure mode the ticket touches (e.g. Ingress and Gateway).
- For new documentation, follow it step by step as a user, using nothing outside it.
- Then list the remaining test gaps and whether the ticket can close, without waiting to be asked. Known limits go in the list explicitly.

## Close-out
Do all of these, then report what changed:
1. Jira: check that every MR is in `Output URL` (it should already be there from MR creation; add any missing), change summary and test results as a comment, required fields and status.
2. Test environment: delete instances you created, keeping one demo instance if the user is still reviewing.
3. When the user asks to close the session: run `session-close <JIRA>` (dry run). Fix every `OPEN` line it prints (unpushed commits, Jira status, Output URL, missing comment) or ask the user about it, then run `session-close <JIRA> --yes`. It kills the session, removes the binding (with a backup), the worktree (keeps the branch), the scratchpad and the `## Temp files` list, and archives the handoff file. Use `--force` only when the user says to skip an open item. Run from inside the session being closed, it kills that session last, so nothing after the `killing` line reaches Discord: send the user its dry-run summary first.

## Ask the user only for
Scope changes, merge or tag without prior authorisation, actions on shared/edge/idp clusters, and anything customer-facing. Bring a recommendation.

## Gotchas
Recurring failures from past tickets. Add to this list when one repeats.
- A file `violet push` can exit 0 without pushing images; check the images really arrived (see the shared knowledge folder).
- Test with the template's real rendering path. A sibling ticket's Ingress form failed to render only under Playwright.
- A green pipeline on the MR says nothing about the merged build. Re-check after merge before installing.
- Don't report that nothing exists from an empty kubectl result without checking the exit code.
- Pick the base image and registry the repo already uses; don't introduce a proxy host found elsewhere.
- Copying a test image to `build-harbor.alauda.cn` from the Mac or devpod fails on large layers (HTTP/2 `INTERNAL_ERROR`); retries don't help. Give the user the copy command right away, single-arch: `skopeo copy --override-os linux --override-arch amd64 docker://<src> docker://build-harbor.alauda.cn/<path>`, and continue when they say it's done.
- `Output URL` is a plain string, so a PUT replaces it. Overwriting with only the new MR drops the earlier ones; always read, append, then write.
