defmodule SymphonyElixir.ClickUp.Client do
  @moduledoc """
  REST client for polling ClickUp tasks from a configured list.
  """

  require Logger
  alias SymphonyElixir.{Config, Tracker.Issue}

  @task_page_size 100
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    list_id = Config.clickup_list_id()

    cond do
      is_nil(Config.clickup_api_token()) ->
        {:error, :missing_clickup_api_token}

      is_nil(list_id) ->
        {:error, :missing_clickup_list_id}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_statuses(list_id, Config.clickup_active_states(), assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      list_id = Config.clickup_list_id()

      cond do
        is_nil(Config.clickup_api_token()) ->
          {:error, :missing_clickup_api_token}

        is_nil(list_id) ->
          {:error, :missing_clickup_list_id}

        true ->
          do_fetch_by_statuses(list_id, normalized, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_tasks_by_ids(ids, assignee_filter)
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(task_id, body) when is_binary(task_id) and is_binary(body) do
    case api_request(:post, "/task/#{task_id}/comment", %{comment_text: body}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, response} ->
        Logger.error(
          "ClickUp create comment failed status=#{response.status}" <>
            error_context(response)
        )

        {:error, :comment_create_failed}

      {:error, reason} ->
        Logger.error("ClickUp create comment failed: #{inspect(reason)}")
        {:error, {:clickup_api_request, reason}}
    end
  end

  @spec update_task_status(String.t(), String.t()) :: :ok | {:error, term()}
  def update_task_status(task_id, status_name) when is_binary(task_id) and is_binary(status_name) do
    case api_request(:put, "/task/#{task_id}", %{status: status_name}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, response} ->
        Logger.error(
          "ClickUp update task status failed status=#{response.status}" <>
            error_context(response)
        )

        {:error, :issue_update_failed}

      {:error, reason} ->
        Logger.error("ClickUp update task status failed: #{inspect(reason)}")
        {:error, {:clickup_api_request, reason}}
    end
  end

  @spec api_request(atom(), String.t(), map() | nil, keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def api_request(method, path, body \\ nil, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &do_request/3)

    case auth_headers() do
      {:ok, headers} ->
        url = build_url(path)
        request_fun.(method, url, %{headers: headers, body: body})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec normalize_task_for_test(map()) :: Issue.t() | nil
  def normalize_task_for_test(task) when is_map(task) do
    normalize_task(task, nil)
  end

  @doc false
  @spec normalize_task_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_task_for_test(task, assignee) when is_map(task) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_task(task, assignee_filter)
  end

  @doc false
  @spec decode_task_list_response_for_test(map() | String.t(), map() | nil) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def decode_task_list_response_for_test(body, assignee_filter \\ nil) do
    decode_task_list_response(body, assignee_filter)
  end

  @doc false
  @spec build_assignee_filter_for_test(String.t(), (atom(), String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map() | nil} | {:error, term()}
  def build_assignee_filter_for_test(assignee, api_request_fun \\ &api_request/2)
      when is_binary(assignee) and is_function(api_request_fun, 2) do
    build_assignee_filter(assignee, api_request_fun)
  end

  @doc false
  @spec do_fetch_tasks_by_ids_for_test([String.t()], map() | nil, (String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]}
  def do_fetch_tasks_by_ids_for_test(ids, assignee_filter, fetch_task_fun)
      when is_list(ids) and is_function(fetch_task_fun, 1) do
    do_fetch_tasks_by_ids(ids, assignee_filter, fetch_task_fun)
  end

  # -- Private: Fetching --

  defp do_fetch_by_statuses(list_id, status_names, assignee_filter) do
    do_fetch_by_statuses_page(list_id, status_names, assignee_filter, 0, [])
  end

  defp do_fetch_by_statuses_page(list_id, status_names, assignee_filter, page, acc) do
    query_string = build_task_query_string(page, status_names)

    case api_request(:get, "/list/#{list_id}/task?#{query_string}") do
      {:ok, %{status: 200, body: body}} ->
        case decode_task_list_response(body, assignee_filter) do
          {:ok, tasks} ->
            updated_acc = Enum.reverse(tasks, acc)

            if length(tasks) >= @task_page_size do
              do_fetch_by_statuses_page(list_id, status_names, assignee_filter, page + 1, updated_acc)
            else
              {:ok, Enum.reverse(updated_acc)}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, response} ->
        Logger.error(
          "ClickUp fetch tasks failed status=#{response.status}" <>
            error_context(response)
        )

        {:error, {:clickup_api_status, response.status}}

      {:error, reason} ->
        Logger.error("ClickUp fetch tasks failed: #{inspect(reason)}")
        {:error, {:clickup_api_request, reason}}
    end
  end

  defp build_task_query_string(page, status_names) do
    base_params = [
      {"page", to_string(page)},
      {"include_closed", "true"},
      {"subtasks", "true"}
    ]

    status_params =
      Enum.map(status_names, fn status -> {"statuses[]", status} end)

    (base_params ++ status_params)
    |> URI.encode_query(:rfc3986)
  end

  defp do_fetch_tasks_by_ids(ids, assignee_filter) do
    do_fetch_tasks_by_ids(ids, assignee_filter, &fetch_single_task/1)
  end

  defp do_fetch_tasks_by_ids(ids, assignee_filter, fetch_task_fun)
       when is_list(ids) and is_function(fetch_task_fun, 1) do
    {tasks, skipped} =
      ids
      |> Task.async_stream(
        fetch_task_fun,
        max_concurrency: 5,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(ids)
      |> Enum.reduce({[], []}, fn
        {{:ok, {:ok, task}}, _id}, {tasks_acc, skipped_acc} ->
          {[task | tasks_acc], skipped_acc}

        {{:ok, {:error, reason}}, id}, {tasks_acc, skipped_acc} ->
          {tasks_acc, [{id, reason} | skipped_acc]}

        {{:exit, reason}, id}, {tasks_acc, skipped_acc} ->
          {tasks_acc, [{id, {:task_exit, reason}} | skipped_acc]}
      end)

    log_skipped_task_refreshes(skipped)

    tasks =
      tasks
      |> Enum.reverse()
      |> Enum.map(&normalize_task(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)

    {:ok, tasks}
  end

  defp fetch_single_task(task_id) do
    case api_request(:get, "/task/#{task_id}") do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _reason} -> {:error, :clickup_invalid_json}
        end

      {:ok, response} ->
        {:error, {:clickup_api_status, response.status}}

      {:error, reason} ->
        {:error, {:clickup_api_request, reason}}
    end
  end

  # -- Private: Response decoding --

  defp decode_task_list_response(%{"tasks" => tasks}, assignee_filter) when is_list(tasks) do
    issues =
      tasks
      |> Enum.map(&normalize_task(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)

    {:ok, issues}
  end

  defp decode_task_list_response(body, assignee_filter) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode_task_list_response(decoded, assignee_filter)
      {:error, _reason} -> {:error, :clickup_invalid_json}
    end
  end

  defp decode_task_list_response(_unknown, _assignee_filter) do
    {:error, :clickup_unknown_payload}
  end

  # -- Private: Task normalization --

  defp normalize_task(task, assignee_filter) when is_map(task) do
    assignees = task["assignees"] || []
    primary_assignee = List.first(assignees)

    %Issue{
      id: to_string(task["id"]),
      identifier: task["custom_id"] || to_string(task["id"]),
      title: task["name"],
      description: task["text_content"] || task["description"],
      priority: parse_priority(task["priority"]),
      state: get_in(task, ["status", "status"]),
      branch_name: nil,
      url: task["url"],
      assignee_id: assignee_field(primary_assignee, "id"),
      blocked_by: extract_dependencies(task),
      labels: extract_tags(task),
      assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
      created_at: parse_unix_ms(task["date_created"]),
      updated_at: parse_unix_ms(task["date_updated"])
    }
  end

  defp normalize_task(_task, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field), do: to_string(assignee[field] || "")
  defp assignee_field(_, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(assignees, %{match_values: match_values})
       when is_list(assignees) and is_struct(match_values, MapSet) do
    Enum.any?(assignees, fn
      %{} = assignee ->
        case assignee_id(assignee) do
          nil -> false
          assignee_id -> MapSet.member?(match_values, assignee_id)
        end

      _ ->
        false
    end)
  end

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    case assignee_id(assignee) do
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee) do
    assignee
    |> Map.get("id")
    |> to_string()
    |> normalize_assignee_match_value()
  end

  defp extract_tags(%{"tags" => tags}) when is_list(tags) do
    tags
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_tags(_), do: []

  defp extract_dependencies(%{"dependencies" => deps}) when is_list(deps) do
    Enum.flat_map(deps, fn
      %{"task_id" => task_id, "depends_on" => depends_on_id}
      when is_binary(task_id) and is_binary(depends_on_id) ->
        [
          %{
            id: depends_on_id,
            identifier: depends_on_id,
            state: nil
          }
        ]

      _ ->
        []
    end)
  end

  defp extract_dependencies(_), do: []

  defp parse_priority(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {priority, _} -> priority
      :error -> nil
    end
  end

  defp parse_priority(%{"id" => id}) when is_integer(id), do: id
  defp parse_priority(_), do: nil

  defp parse_unix_ms(nil), do: nil

  defp parse_unix_ms(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {unix_ms, _} -> parse_unix_ms(unix_ms)
      :error -> nil
    end
  end

  defp parse_unix_ms(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_unix_ms(_), do: nil

  # -- Private: Auth & HTTP --

  defp auth_headers do
    case Config.clickup_api_token() do
      nil ->
        {:error, :missing_clickup_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp build_url(path) do
    base = Config.clickup_endpoint()
    String.trim_trailing(base, "/") <> path
  end

  defp do_request(:get, url, %{headers: headers}) do
    Req.get(url,
      headers: headers,
      connect_options: [timeout: 30_000]
    )
  end

  defp do_request(:post, url, %{headers: headers, body: body}) do
    Req.post(url,
      headers: headers,
      json: body || %{},
      connect_options: [timeout: 30_000]
    )
  end

  defp do_request(:put, url, %{headers: headers, body: body}) do
    Req.put(url,
      headers: headers,
      json: body || %{},
      connect_options: [timeout: 30_000]
    )
  end

  defp do_request(:delete, url, %{headers: headers, body: body}) do
    Req.delete(url,
      headers: headers,
      json: body || %{},
      connect_options: [timeout: 30_000]
    )
  end

  # -- Private: Assignee filtering --

  defp routing_assignee_filter do
    case Config.clickup_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    build_assignee_filter(assignee, &api_request/2)
  end

  defp build_assignee_filter(assignee, api_request_fun)
       when is_binary(assignee) and is_function(api_request_fun, 2) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter(api_request_fun)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    resolve_viewer_assignee_filter(&api_request/2)
  end

  defp resolve_viewer_assignee_filter(api_request_fun) when is_function(api_request_fun, 2) do
    case api_request_fun.(:get, "/user") do
      {:ok, %{status: 200, body: body}} ->
        case extract_viewer_id(body) do
          nil ->
            {:error, :missing_clickup_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_clickup_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_viewer_id(%{"user" => %{} = user}), do: assignee_id(user)
  defp extract_viewer_id(%{"id" => _id} = payload), do: assignee_id(payload)

  defp extract_viewer_id(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> extract_viewer_id(decoded)
      {:error, _reason} -> nil
    end
  end

  defp extract_viewer_id(_body), do: nil

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp log_skipped_task_refreshes([]), do: :ok

  defp log_skipped_task_refreshes(skipped) when is_list(skipped) do
    Enum.each(Enum.reverse(skipped), fn {id, reason} ->
      Logger.warning(
        "ClickUp task refresh skipped task_id=#{inspect(id)} reason=#{inspect(reason)}"
      )
    end)
  end

  # -- Private: Error helpers --

  defp error_context(response) do
    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
