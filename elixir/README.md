# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls your issue tracker (Linear or ClickUp) for candidate work
2. Creates an isolated workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side tool for raw tracker API calls:
- **Linear**: `linear_graphql` — raw GraphQL queries/mutations against Linear
- **ClickUp**: `clickup_api` — raw REST API requests against ClickUp

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Set up your issue tracker credentials (see [Tracker Setup](#tracker-setup) below).
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and tracker-specific skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
   - The `clickup` skill expects Symphony's `clickup_api` app-server tool for raw ClickUp REST API
     operations such as task management, comments, and status updates.
5. Customize the copied `WORKFLOW.md` file for your project.
   - **Linear**: To get your project's slug, right-click the project and copy its URL. The slug is
     part of the URL. Note that Symphony depends on non-standard Linear issue statuses: "Rework",
     "Human Review", and "Merging". You can customize them in Team Settings → Workflow in Linear.
   - **ClickUp**: You'll need your ClickUp list ID and optionally a team ID. See
     [ClickUp Setup](#clickup-setup) below.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Tracker Setup

Symphony supports **Linear** and **ClickUp** as issue trackers. Configure one via the
`tracker.kind` field in your `WORKFLOW.md`.

### Linear Setup

1. Go to **Linear** → **Settings** → **Security & access** → **Personal API keys**.
2. Create a new personal API key.
3. Set the key as the `LINEAR_API_KEY` environment variable:
   ```bash
   export LINEAR_API_KEY="lin_api_..."
   ```
   Alternatively, set `tracker.api_key` directly in your `WORKFLOW.md` (not recommended for
   shared repos).
4. Configure `WORKFLOW.md` with `tracker.kind: linear` and your `project_slug`.

### ClickUp Setup

1. **Get your ClickUp API key**:
   - Go to [app.clickup.com](https://app.clickup.com) and log in.
   - Click your avatar (bottom-left) → **Settings** → **Apps**.
   - Under **API Token**, click **Generate** (or copy your existing token).
   - The token looks like `pk_12345678_ABCDEFGHIJKLMNOPQRSTUVWXYZ`.
2. **Set the API key as an environment variable**:
   ```bash
   export CLICKUP_API_KEY="pk_12345678_..."
   ```
   Alternatively, set `tracker.api_key` in your `WORKFLOW.md`.
3. **Find your ClickUp List ID**:
   - Navigate to the list you want Symphony to poll for tasks.
   - Click the **ellipsis menu** (⋯) on the list → **Copy link**.
   - The list ID is the numeric value in the URL (e.g., `https://app.clickup.com/12345/v/li/900100200300` → list ID is `900100200300`).
4. **(Optional) Find your Team ID**:
   - Your Team (Workspace) ID can be found by calling `GET https://api.clickup.com/api/v2/team`
     with your API key, or from your ClickUp workspace URL.
5. **Configure `WORKFLOW.md`**:
   ```yaml
   tracker:
     kind: clickup
     api_key: $CLICKUP_API_KEY
     list_id: "900100200300"
     team_id: "12345678"          # optional
     active_states:
       - to do
       - in progress
     terminal_states:
       - complete
       - closed
   ```
   - `list_id` **(required)**: The ClickUp list to poll for tasks.
   - `team_id` (optional): Your ClickUp workspace/team ID.
   - `active_states`: Status names that Symphony will pick up and work on. These are
     case-insensitive and must match the custom statuses configured in your ClickUp list/space.
   - `terminal_states`: Status names that indicate completed work.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal Linear example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Minimal ClickUp example:

```md
---
tracker:
  kind: clickup
  api_key: $CLICKUP_API_KEY
  list_id: "900100200300"
  active_states:
    - to do
    - in progress
  terminal_states:
    - complete
    - closed
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a ClickUp task {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` (for Linear) or `CLICKUP_API_KEY` (for ClickUp)
  when unset or when value is `$LINEAR_API_KEY` / `$CLICKUP_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
