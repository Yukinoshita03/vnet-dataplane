# Issue tracker: GitHub

Issues and PRDs for this repository live as GitHub issues in
`Yukinoshita03/vnet-dataplane`. Use the `gh` CLI for issue operations.

## Conventions

- Create: `gh issue create --title "..." --body "..."`
- Read: `gh issue view <number> --comments`
- List: `gh issue list --state open --json number,title,body,labels,comments`
- Comment: `gh issue comment <number> --body "..."`
- Label: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- Close: `gh issue close <number> --comment "..."`

Infer the repository from `git remote -v`; `gh` does this automatically when
run inside this clone.

## Pull requests as a triage surface

**PRs as a request surface: no.**

Pull requests are not included in the issue triage queue. This flag can be
changed here later if the repository starts treating external pull requests
as feature requests.

## Skill operations

When a skill says "publish to the issue tracker", create a GitHub issue. When
it says "fetch the relevant ticket", run
`gh issue view <number> --comments`.

For wayfinding workflows:

- A map is one issue labelled `wayfinder:map`.
- Child tickets use `wayfinder:research`, `wayfinder:prototype`,
  `wayfinder:grilling`, or `wayfinder:task`.
- Prefer GitHub sub-issues and native issue dependencies. When unavailable,
  use `Part of #<map>` and `Blocked by: #<number>` in issue bodies.
- A ticket is ready for an agent only when it has no open blocker and no
  current assignee.
- Claim a ticket with `gh issue edit <number> --add-assignee @me`.
- Resolve it by posting the result, closing the issue, and updating the map's
  decisions or context pointer.
