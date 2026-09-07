# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue:** `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue:** `gh issue view <number> --comments`, filtering comments with `jq` and fetching labels.
- **List issues:** `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with the needed `--label` and `--state` filters.
- **Comment on an issue:** `gh issue comment <number> --body "..."`
- **Apply or remove labels:** `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- **Close an issue:** `gh issue close <number> --comment "..."`

Infer the repository from `git remote -v`. The `gh` CLI does this automatically when run inside the clone.

## Pull requests as a triage surface

**PRs as a request surface: no.** Set this to `yes` if the repo later treats external pull requests as feature requests. The `/triage` skill reads this flag.

When set to `yes`, pull requests use the same labels and states as issues:

- **Read a pull request:** `gh pr view <number> --comments` and `gh pr diff <number>`
- **List external pull requests for triage:** `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments`, then keep only `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE` authors.
- **Comment, label, or close:** use `gh pr comment`, `gh pr edit --add-label` or `--remove-label`, and `gh pr close`.

GitHub shares one number space across issues and pull requests. A bare `#42` may refer to either. Try `gh pr view 42`, then fall back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

The `/wayfinder` skill uses one map issue with child issues as tickets.

- **Map:** a single issue labelled `wayfinder:map`, holding the Notes, Decisions-so-far, and Fog sections. Create it with `gh issue create --label wayfinder:map`.
- **Child ticket:** an issue linked to the map as a GitHub sub-issue through `gh api`. If sub-issues are unavailable, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Use a `wayfinder:<type>` label, where the type is `research`, `prototype`, `grilling`, or `task`. Once claimed, assign the ticket to the developer doing the work.
- **Blocking:** use GitHub's native issue dependencies. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`. Get the numeric database ID with `gh api repos/<owner>/<repo>/issues/<n> --jq .id`. Do not use the issue number or `node_id`. If dependencies are unavailable, put `Blocked by: #<n>, #<n>` at the top of the child body.
- **Frontier query:** list the map's open children, remove tickets with an open blocker or an assignee, and take the first remaining ticket in map order.
- **Claim:** `gh issue edit <n> --add-assignee @me`. This is the session's first write.
- **Resolve:** comment with the answer, close the child issue, then append a context link to the map's Decisions-so-far section.
