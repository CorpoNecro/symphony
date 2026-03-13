defmodule SymphonyElixir.ClickUp.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClickUp.Client

  @sample_task %{
    "id" => "abc123",
    "custom_id" => "TASK-42",
    "name" => "Fix the widget",
    "text_content" => "The widget is broken and needs fixing.",
    "status" => %{
      "status" => "in progress",
      "type" => "custom",
      "color" => "#7C4DFF"
    },
    "priority" => %{"id" => "2"},
    "url" => "https://app.clickup.com/t/abc123",
    "assignees" => [
      %{"id" => 12_345, "username" => "alice"}
    ],
    "tags" => [
      %{"name" => "Bug"},
      %{"name" => "Urgent"}
    ],
    "dependencies" => [],
    "date_created" => "1700000000000",
    "date_updated" => "1700001000000"
  }

  test "normalize_task_for_test produces a Tracker.Issue from ClickUp task JSON" do
    issue = Client.normalize_task_for_test(@sample_task)

    assert %Issue{} = issue
    assert issue.id == "abc123"
    assert issue.identifier == "TASK-42"
    assert issue.title == "Fix the widget"
    assert issue.description == "The widget is broken and needs fixing."
    assert issue.priority == 2
    assert issue.state == "in progress"
    assert issue.url == "https://app.clickup.com/t/abc123"
    assert issue.assignee_id == "12345"
    assert issue.labels == ["bug", "urgent"]
    assert issue.blocked_by == []
    assert issue.assigned_to_worker == true
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at
  end

  test "normalize_task_for_test handles task without custom_id" do
    task = Map.delete(@sample_task, "custom_id")
    issue = Client.normalize_task_for_test(task)

    assert issue.identifier == "abc123"
  end

  test "normalize_task_for_test handles nil assignees" do
    task = Map.put(@sample_task, "assignees", [])
    issue = Client.normalize_task_for_test(task)

    assert issue.assignee_id == nil
    assert issue.assigned_to_worker == true
  end

  test "normalize_task_for_test handles missing tags" do
    task = Map.delete(@sample_task, "tags")
    issue = Client.normalize_task_for_test(task)

    assert issue.labels == []
  end

  test "normalize_task_for_test handles nil priority" do
    task = Map.put(@sample_task, "priority", nil)
    issue = Client.normalize_task_for_test(task)

    assert issue.priority == nil
  end

  test "normalize_task_for_test with assignee filter" do
    issue = Client.normalize_task_for_test(@sample_task, "12345")

    assert issue.assigned_to_worker == true

    issue_wrong = Client.normalize_task_for_test(@sample_task, "99999")

    assert issue_wrong.assigned_to_worker == false
  end

  test "normalize_task_for_test handles dependencies" do
    task =
      Map.put(@sample_task, "dependencies", [
        %{"task_id" => "abc123", "depends_on" => "dep456"}
      ])

    issue = Client.normalize_task_for_test(task)

    assert [%{id: "dep456", identifier: "dep456", state: nil}] = issue.blocked_by
  end

  test "fetch_candidate_issues fails without api token" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "clickup",
      tracker_api_token: nil
    )

    assert {:error, :missing_clickup_api_token} = Client.fetch_candidate_issues()
  end

  test "fetch_candidate_issues fails without list_id" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "clickup",
      tracker_api_token: "ck_test_token"
    )

    assert {:error, :missing_clickup_list_id} = Client.fetch_candidate_issues()
  end

  test "decode_task_list_response_for_test preserves assignee filter for binary payloads" do
    body = Jason.encode!(%{"tasks" => [@sample_task]})

    assert {:ok, [issue]} = Client.decode_task_list_response_for_test(body, "99999")
    assert issue.assigned_to_worker == false

    assert {:ok, [matching_issue]} = Client.decode_task_list_response_for_test(body, "12345")
    assert matching_issue.assigned_to_worker == true
  end

  test "api_request supports delete through the default dispatcher" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "clickup",
      tracker_api_token: "ck_test_token",
      tracker_endpoint: "http://127.0.0.1:1"
    )

    assert {:error, _reason} = Client.api_request(:delete, "/task/abc123")
  end
end
