# Triage Labels

Issues carry two kinds of label: a **status** label (where the issue is in triage) and a **category** label (what the issue is about). A normal issue has one of each — e.g. a new bug report opens as `needs-triage` + `bug`, then a maintainer moves the status to `ready-for-agent` while the `bug` category stays.

## Status labels

The skills speak in terms of five canonical triage roles. This table maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Category labels

These describe what an issue is about, independent of its triage status. The issue forms under `.github/ISSUE_TEMPLATE/` apply one automatically alongside `needs-triage`.

| Label         | Meaning                          | Applied by            |
| ------------- | -------------------------------- | --------------------- |
| `bug`         | Something isn't working          | Bug report form       |
| `enhancement` | New feature or request           | Feature request form  |
