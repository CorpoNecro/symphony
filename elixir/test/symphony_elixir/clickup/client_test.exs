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

  test "normalize_task_for_test handles invalid unix timestamps without raising" do
    task =
      @sample_task
      |> Map.put("date_created", "999999999999999999999999999999")
      |> Map.put("date_updated", 999_999_999_999_999_999_999_999_999_999)

    issue = Client.normalize_task_for_test(task)

    assert issue.created_at == nil
    assert issue.updated_at == nil
  end

  test "normalize_task_for_test with assignee filter" do
    issue = Client.normalize_task_for_test(@sample_task, "12345")

    assert issue.assigned_to_worker == true

    issue_wrong = Client.normalize_task_for_test(@sample_task, "99999")

    assert issue_wrong.assigned_to_worker == false
  end

  test "normalize_task_for_test with assignee filter matches any assignee on the task" do
    task_with_multiple_assignees =
      Map.put(@sample_task, "assignees", [
        %{"id" => "11111", "username" => "alice"},
        %{"id" => "12345", "username" => "bob"}
      ])

    issue = Client.normalize_task_for_test(task_with_multiple_assignees, "12345")
    assert issue.assigned_to_worker == true
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

  test "build_assignee_filter_for_test resolves me from the current ClickUp user payload" do
    assert {:ok, %{configured_assignee: "me", match_values: match_values}} =
             Client.build_assignee_filter_for_test("me", fn
               :get, "/user" ->
                 {:ok, %{status: 200, body: %{"user" => %{"id" => 42_424}}}}
             end)

    assert MapSet.member?(match_values, "42424")
  end

  test "do_fetch_tasks_by_ids_for_test continues when one task refresh fails" do
    second_task =
      @sample_task
      |> Map.put("id", "xyz789")
      |> Map.put("custom_id", "TASK-99")
      |> Map.put("name", "Second task")

    assert {:ok, issues} =
             Client.do_fetch_tasks_by_ids_for_test(
               ["abc123", "missing-task", "xyz789"],
               nil,
               fn
                 "abc123" -> {:ok, @sample_task}
                 "missing-task" -> {:error, {:clickup_api_status, 404}}
                 "xyz789" -> {:ok, second_task}
               end
             )

    assert Enum.map(issues, & &1.id) == ["abc123", "xyz789"]
  end

  test "do_fetch_tasks_by_ids_for_test returns remaining tasks when one worker exits" do
    assert {:ok, issues} =
             Client.do_fetch_tasks_by_ids_for_test(
               ["abc123", "crash-task"],
               nil,
               fn
                 "abc123" -> {:ok, @sample_task}
                 "crash-task" -> exit(:timeout)
               end
             )

    assert Enum.map(issues, & &1.id) == ["abc123"]
  end

  test "do_fetch_tasks_by_ids_for_test returns error for failed single-task refresh" do
    assert {:error, {:clickup_api_status, 503}} =
             Client.do_fetch_tasks_by_ids_for_test(
               ["abc123"],
               nil,
               fn "abc123" -> {:error, {:clickup_api_status, 503}} end
             )
  end

  test "do_fetch_tasks_by_ids_for_test returns timeout error for single-task worker exit" do
    assert {:error, :task_fetch_timeout} =
             Client.do_fetch_tasks_by_ids_for_test(
               ["abc123"],
               nil,
               fn "abc123" -> exit(:timeout) end
             )
  end

  test "do_fetch_by_statuses_for_test paginates using raw ClickUp page size" do
    page_zero_tasks =
      Enum.map(1..99, fn index ->
        %{
          "id" => "p0-#{index}",
          "name" => "Page 0 Task #{index}",
          "status" => %{"status" => "todo"},
          "assignees" => []
        }
      end) ++ [nil]

    page_one_tasks = [
      %{
        "id" => "p1-1",
        "name" => "Page 1 Task 1",
        "status" => %{"status" => "todo"},
        "assignees" => []
      }
    ]

    assert {:ok, issues} =
             Client.do_fetch_by_statuses_for_test(
               "list-123",
               ["todo"],
               nil,
               fn
                 :get, path ->
                   cond do
                     String.contains?(path, "page=0") ->
                       {:ok, %{status: 200, body: %{"tasks" => page_zero_tasks}}}

                     String.contains?(path, "page=1") ->
                       {:ok, %{status: 200, body: %{"tasks" => page_one_tasks}}}

                     true ->
                       flunk("unexpected page path: #{path}")
                    end
               end
             )

    assert Enum.any?(issues, &(&1.id == "p1-1"))
  end
end
