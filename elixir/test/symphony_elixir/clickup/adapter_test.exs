defmodule SymphonyElixir.ClickUp.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClickUp.Adapter

  test "adapter implements all Tracker callbacks" do
    behaviours = Adapter.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    assert SymphonyElixir.Tracker in behaviours
  end

  test "adapter delegates to configurable client module" do
    test_pid = self()

    defmodule MockClickUpClient do
      def fetch_candidate_issues do
        send(Process.get(:test_pid), :fetch_candidate_issues_called)
        {:ok, []}
      end

      def fetch_issues_by_states(_states) do
        send(Process.get(:test_pid), :fetch_issues_by_states_called)
        {:ok, []}
      end

      def fetch_issue_states_by_ids(_ids) do
        send(Process.get(:test_pid), :fetch_issue_states_by_ids_called)
        {:ok, []}
      end

      def create_comment(_id, _body) do
        send(Process.get(:test_pid), :create_comment_called)
        :ok
      end

      def update_task_status(_id, _state) do
        send(Process.get(:test_pid), :update_task_status_called)
        :ok
      end
    end

    Application.put_env(:symphony_elixir, :clickup_client_module, MockClickUpClient)
    Process.put(:test_pid, test_pid)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :clickup_client_module)
    end)

    assert {:ok, []} = Adapter.fetch_candidate_issues()
    assert_received :fetch_candidate_issues_called

    assert {:ok, []} = Adapter.fetch_issues_by_states(["to do"])
    assert_received :fetch_issues_by_states_called

    assert {:ok, []} = Adapter.fetch_issue_states_by_ids(["123"])
    assert_received :fetch_issue_states_by_ids_called

    assert :ok = Adapter.create_comment("123", "Hello")
    assert_received :create_comment_called

    assert :ok = Adapter.update_issue_state("123", "done")
    assert_received :update_task_status_called
  end
end
