# Skills

A curated collection of agent skills compatible with the [open agent skills ecosystem](https://skills.sh). Install them in Claude Code, OpenCode, Codex, Gemini CLI, Cursor, and [60+ other agents](https://github.com/vercel-labs/skills#supported-agents).

## Install

```bash
# Install all skills
npx skills add andresjz/skills

# Install a specific skill
npx skills add andresjz/skills@code-review
```

Use `-g` to install globally (available across all projects):

```bash
npx skills add andresjz/skills -g
```

## Skills

| Skill | Description | Source |
|-------|-------------|--------|
| [code-review](skills/code-review) | Two-axis code review: checks conformance to repo coding standards and spec/PRD compliance. Runs parallel sub-agents for each axis. | [mattpocock/skills](https://github.com/mattpocock/skills) |
| [webapp-testing](skills/webapp-testing) | Playwright-based toolkit for testing local web apps. Supports screenshot capture, browser logs, UI debugging, and frontend verification. | [anthropics/skills](https://github.com/anthropics/skills) |
| [find-skills](skills/find-skills) | Meta-skill that helps discover and install other skills from the ecosystem via `npx skills find`. | [vercel-labs/skills](https://github.com/vercel-labs/skills) |
| [python-testing-patterns](skills/python-testing-patterns) | Comprehensive pytest testing strategies: fixtures, mocking, parameterization, and TDD workflows. | [wshobson/agents](https://github.com/wshobson/agents) |
| [review-pr](skills/review-pr) | Review GitHub PRs against `.github/instructions`, post structured comments with suggestions. Supports CI and interactive mode. | Original |
| [git-workflow-and-versioning](skills/git-workflow-and-versioning) | Git workflow practices: committing, branching, conflict resolution, semantic versioning, releases, and changelogs. | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) |

## Compatible Agents

These skills work with any agent that supports the skills ecosystem, including:

- Claude Code
- Cursor
- Codex
- Gemini CLI
- OpenCode
- Windsurf
- GitHub Copilot
- Cline / Roo Code
- [and 60+ more](https://github.com/vercel-labs/skills#supported-agents)

## Browse More Skills

Visit [skills.sh](https://skills.sh) to discover skills from the community.

## License

MIT. Individual skills may have their own licenses — see each skill directory.
