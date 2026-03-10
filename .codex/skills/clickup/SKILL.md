---
name: clickup
description: |
  Use Symphony's `clickup_api` client tool for raw ClickUp REST API
  operations such as task management, comment creation, and status updates.
---

# ClickUp REST API

Use this skill for raw ClickUp API work during Symphony app-server sessions.

## Primary tool

Use the `clickup_api` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured ClickUp auth for the session.

Tool input:

```json
{
  "method": "GET",
  "path": "/task/{task_id}",
  "body": null
}
```

Tool behavior:

- Send one REST API call per tool call.
- `method` must be one of `GET`, `POST`, `PUT`, `DELETE`.
- `path` is relative to the ClickUp v2 base URL (`https://api.clickup.com/api/v2`).
- `body` is optional JSON for POST/PUT requests.
- Check the response `status` field; 2xx indicates success.

## Common workflows

### Get a task by ID

```json
{
  "method": "GET",
  "path": "/task/{task_id}"
}
```

### Get tasks from a list

```json
{
  "method": "GET",
  "path": "/list/{list_id}/task?statuses[]=to do&statuses[]=in progress&page=0"
}
```

Query parameters:
- `statuses[]` — filter by status names (repeat for multiple)
- `page` — page number (0-indexed), max 100 tasks per page
- `include_closed` — set to `true` to include closed tasks
- `subtasks` — set to `true` to include subtasks
- `assignees[]` — filter by assignee user IDs

### Create a comment on a task

```json
{
  "method": "POST",
  "path": "/task/{task_id}/comment",
  "body": {
    "comment_text": "Plain text comment content"
  }
}
```

For rich text comments, use the `comment` array format:

```json
{
  "method": "POST",
  "path": "/task/{task_id}/comment",
  "body": {
    "comment": [
      {"text": "Comment with "},
      {"text": "a link", "attributes": {"link": "https://example.com"}}
    ]
  }
}
```

### Update a task's status

```json
{
  "method": "PUT",
  "path": "/task/{task_id}",
  "body": {
    "status": "in progress"
  }
}
```

### Update a task (general fields)

```json
{
  "method": "PUT",
  "path": "/task/{task_id}",
  "body": {
    "name": "Updated task name",
    "description": "Updated description",
    "priority": 2,
    "due_date": 1700000000000,
    "assignees": {"add": [12345], "rem": []}
  }
}
```

### Get comments on a task

```json
{
  "method": "GET",
  "path": "/task/{task_id}/comment"
}
```

### Update an existing comment

```json
{
  "method": "PUT",
  "path": "/comment/{comment_id}",
  "body": {
    "comment_text": "Updated comment text"
  }
}
```

### Get teams (workspaces)

```json
{
  "method": "GET",
  "path": "/team"
}
```

### Get spaces in a workspace

```json
{
  "method": "GET",
  "path": "/team/{team_id}/space"
}
```

### Get lists in a folder

```json
{
  "method": "GET",
  "path": "/folder/{folder_id}/list"
}
```

### Create a task

```json
{
  "method": "POST",
  "path": "/list/{list_id}/task",
  "body": {
    "name": "New task name",
    "description": "Task description",
    "status": "to do",
    "priority": 3,
    "assignees": [12345],
    "tags": ["bug"]
  }
}
```

### Add a dependency

```json
{
  "method": "POST",
  "path": "/task/{task_id}/dependency",
  "body": {
    "depends_on": "{blocking_task_id}"
  }
}
```

## ClickUp concepts

- **Workspace (Team)** — top-level container, identified by `team_id`
- **Space** — organizational unit within a workspace
- **Folder** — grouping within a space
- **List** — container for tasks (analogous to a Linear project)
- **Task** — the work item (analogous to a Linear issue)
- **Custom Status** — each list/space can have its own status workflow

## Usage rules

- Use `clickup_api` for task management, comments, and ad-hoc ClickUp API calls.
- Status names are case-insensitive strings specific to each list/space.
- ClickUp uses Unix timestamps in milliseconds for date fields.
- Pagination is page-based (0-indexed), with a max of 100 tasks per page.
- Do not introduce new raw-token shell helpers for API access.
