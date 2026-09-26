# Agent instructions

This project uses Jig, a vendor-neutral agent SDLC framework. Project knowledge lives in
`.ai/knowledge/`; the development process is provided by `jig-*` skills backed by
deterministic scripts in `.ai/scripts/`.

<!-- jig:begin -->
<!-- Everything between the jig markers is written by `jig upgrade`, so improvements to
     what Jig tells an agent reach this file on their own. Change anything in here and
     jig keeps your version and stops updating the section; `jig status` says so.
     Your own rules belong below the end marker, where nothing overwrites them. -->

## Jig first

Each row is a moment where a runtime offers its own way of doing the same thing. The middle
column is the way; the right-hand one is what it replaces.

| When you need to | Use | Instead of |
|---|---|---|
| Take on work someone described | the `jig-task` skill | starting to edit code straight away |
| Decide how much process the work needs | the risk test in the `jig-task` skill | reading a class off one word in the route table |
| File the work as a unit | `jig task new <id>` | the runtime's own background tasks (`spawn_task` in Claude Code): they open another session, not a task with a route, a workspace and consolidation |
| Get a branch for the task, or a tree of its own | `jig task start <id>`, or `jig task start <id> --worktree` | `git checkout -b`, `git worktree add` |
| Find what to read for the files you touch | `jig context --files <files>` | grepping `.ai/knowledge/`, or reading all of it |
| Write one of the task's documents | `jig task artifact write <id> <kind> --from <file>` | your editing tools on a path under `.ai/workspace/` |
| Show the work is done | `jig verify` | running the test commands yourself |
| Reach a commit and a pull request | `jig task ship <id> --message-file <file>` | `git commit`, `gh pr create` |

Keep this table short: eight rows get read; twenty stop being read, exactly as prose does. A
session to-do list (`TodoWrite` and the like) is deliberately absent — it is a draft for one
session, not a unit of work, and nothing here replaces it.

## Read first

- `.ai/knowledge/GLOSSARY.md` — canonical terms; use them in code and docs.
- `.ai/knowledge/RULES.md` — rules and invariants; never violate them.
- `.ai/knowledge/ARCHITECTURE.md` — domains, boundaries, dependency directions.
- `.ai/knowledge/adr/` — accepted decisions; propose a new ADR instead of silently
  contradicting one.

Do not read all of `.ai/knowledge/` up front. Ask the scripts for what is relevant:

```
.ai/scripts/jig context --files <changed files>
```

## Workflow

Start work with the `jig-task` skill; it classifies the task by risk and names the route.
Stage skills can also be used directly: `jig-analyze`, `jig-implement`, `jig-review`,
`jig-verify`, `jig-consolidate`, `jig-architecture-review`.

Three skills sit outside the task routes. Two populate knowledge rather than change
code: `jig-map` proposes per-domain knowledge, and `jig-accept` decides what is proposed.
A proposed document is invisible to `jig context` until a human accepts it, so knowledge
someone wrote but nobody agreed to reaches no agent — `jig status` reports the count on
its `proposals:` line, and `jig knowledge proposed` lists it. The third, `jig-idea`, works
before a route: it stress-tests an idea and keeps the result as a specification with a
roadmap under `.ai/specs/<id>/`. A specification is a plan, not knowledge, so `jig context`
never resolves it — `jig status` counts specs on its `specs:` line, and `jig spec list`
lists them with their roadmap progress. A spec released once, at the end, is built on an
epic branch (`jig spec epic`): its tasks are cut from the epic and their pull requests go
into it.

`jig-autopilot` runs one task's route without waiting between stages and stops only where a
human is needed; the route, the gates and `agent.git` stay what they are.

`jig-setup` asks a person, one question at a time, how far their agent may go on its own and
writes the answers to their gitignored `.ai/config.local.yaml` through
`jig config set --local`; it never writes `.ai/config.yaml`.

**Three questions decide the class**, asked about this change being wrong after it shipped:
what takes it back; how far the mistake reaches — this repository, or users, money, somebody
else's system; and who finds it — a test and the next run, or the person it hurt. The class is
the **highest** one whose answers fit; the full test, with examples, is in the `jig-task` skill.

| Class | Route |
|---|---|
| T0 trivial | implement, verify, consolidate |
| T1 local | analyze, implement, verify, consolidate |
| T2 structural | analyze, plan, implement, review, verify, consolidate |
| T3 architectural | discover, design, human gate, implement, architecture review, verify, consolidate |
| T4 critical | discover, specify, alternatives, design, human gate, implement, independent review, verify, consolidate |

Every route ends in consolidation, and a task with a workspace ends it in two records.
Before the commit, the knowledge decision — `NO_DURABLE_KNOWLEDGE` included — is recorded
with `jig task set <id> knowledge_consolidated true`. After the change has landed, when
`jig status` counts it under `needs consolidation`, the task is closed with
`jig task set <id> status consolidated`. A merge alone never closes a task.

Risk sets the floor: a one-line change to authentication is not trivial. When a task
turns out bigger, re-classify with `jig task set <id> class Tn` and run the stages the
new class requires.
<!-- jig:end -->

## Working rules

- Code explains what; knowledge explains why. Put intent, constraints, trade-offs and
  rejected alternatives into `.ai/knowledge/`, not into task notes.
- State here which natural language the project's **durable** artifacts are written in —
  knowledge documents, ADRs, code comments — if the project cares. This file is committed
  and every runtime reads it, so it is the one place where the answer is the same for
  every contributor.

  Two things are deliberately outside that answer. The language an agent *speaks* in a
  session is a personal preference: set it in your own runtime's local instruction file.
  And **task artifacts under `.ai/workspace/tasks/` follow the same personal preference**,
  not this rule — they are gitignored, they never leave the machine, and their reader is
  the person at the human gate. A design nobody else will read is worth writing in the
  language its reader thinks in.
- Task-specific notes belong in `.ai/workspace/tasks/<id>/` (gitignored). They never
  become repository documentation by themselves.
- Completion is proven by evidence: run `.ai/scripts/jig verify` before declaring done.
- Before finishing a task, decide what should survive it. Update `.ai/knowledge/`, or
  state `NO_DURABLE_KNOWLEDGE` — and record the decision in task state
  (`jig-consolidate`). Frontmatter is maintained by `jig knowledge new`,
  `jig knowledge paths add|remove` and `jig knowledge reviewed`, never by hand.
- Knowledge authority, highest first: human instruction, accepted ADR, architecture,
  rules and invariants, conventions, glossary, feature knowledge, task context.
  Escalate real conflicts to a human.
