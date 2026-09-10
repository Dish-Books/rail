defmodule Rail.Roles.Actions.RecentFinishedRuns do
  @moduledoc false

  import Ecto.Query
  import Rail.Roles.Utils.Truncate

  alias Rail.Domain.Enums.RunStatus
  alias Rail.Domain.Enums.TaskStage
  alias Rail.Repo
  alias Rail.Roles.RoleRunRecord
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun

  @default_limit 5
  @default_max_chars 4000
  @default_head_chars 2000
  @default_tail_chars 2000
  @default_statuses [:finished, :adopted_dead]

  def recent_finished_runs(_scope, role_id, opts \\ []) when is_binary(role_id) do
    fetch_recent_runs(role_id, opts)
  end

  defp fetch_recent_runs(role_id, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    head_chars = Keyword.get(opts, :head_chars, @default_head_chars)
    tail_chars = Keyword.get(opts, :tail_chars, @default_tail_chars)

    statuses =
      opts
      |> Keyword.get(:statuses, @default_statuses)
      |> Enum.filter(&(&1 in RunStatus.values()))

    query =
      from(rr in RoleRun,
        where: rr.role_id == ^role_id and rr.pruned == false and rr.status in ^statuses,
        order_by: [desc: fragment("COALESCE(?, ?)", rr.completed_at, rr.started_at)],
        preload: [:run_events]
      )

    role_runs = Repo.all(query)
    role = Keyword.get(opts, :role) || Repo.get(Role, role_id)

    collect_records(role_runs, [], limit, role, max_chars, head_chars, tail_chars, opts)
  end

  defp collect_records([], acc, _limit, _role, _max_chars, _head_chars, _tail_chars, _opts) do
    Enum.reverse(acc)
  end

  defp collect_records(_runs, acc, limit, _role, _max_chars, _head_chars, _tail_chars, _opts) when length(acc) >= limit do
    Enum.reverse(acc)
  end

  defp collect_records([rr | rest], acc, limit, role, max_chars, head_chars, tail_chars, opts) do
    case extract_valid_transcript(rr, opts) do
      {:ok, text} ->
        record = build_record(rr, text, role, max_chars, head_chars, tail_chars, opts)
        collect_records(rest, [record | acc], limit, role, max_chars, head_chars, tail_chars, opts)

      :skip ->
        collect_records(rest, acc, limit, role, max_chars, head_chars, tail_chars, opts)
    end
  end

  defp extract_valid_transcript(rr, opts) do
    case extract_transcript(rr, opts) do
      text when is_binary(text) and byte_size(text) > 0 ->
        trimmed = String.trim(text)
        if trimmed == "", do: :skip, else: {:ok, trimmed}

      _other ->
        :skip
    end
  end

  defp extract_transcript(rr, opts) do
    case Keyword.get(opts, :transcript_reader) do
      reader when is_function(reader, 1) ->
        reader.(rr)

      nil ->
        if rr.output && String.trim(rr.output) != "" do
          rr.output
        else
          events = rr.run_events || []

          if events == [] do
            nil
          else
            Enum.map_join(events, "\n", & &1.line)
          end
        end
    end
  end

  defp build_record(rr, raw_text, role, max_chars, head_chars, tail_chars, opts) do
    truncated = truncate_head_tail(raw_text, max_chars, head_chars, tail_chars)
    title = resolve_title(rr.task_id, opts[:tasks])
    stage = resolve_stage(role, opts)
    duration = calculate_duration(rr.started_at, rr.completed_at)

    %RoleRunRecord{
      task_id: rr.task_id,
      title: title,
      stage: stage,
      status: rr.status,
      exit_code: rr.exit_code,
      duration: duration,
      usage: rr.usage,
      error: rr.error,
      transcript_text: truncated,
      completed_at: rr.completed_at
    }
  end

  defp resolve_title(task_id, tasks) when is_list(tasks) do
    case Enum.find(tasks, fn item -> is_map(item) and (item[:id] == task_id or item["id"] == task_id) end) do
      %{title: title} -> title
      %{"title" => title} -> title
      nil -> "Task #{task_id}"
    end
  end

  defp resolve_title(task_id, tasks) when is_map(tasks) do
    case Map.get(tasks, task_id) do
      %{title: title} -> title
      %{"title" => title} -> title
      title when is_binary(title) -> title
      nil -> "Task #{task_id}"
    end
  end

  defp resolve_title(task_id, _other), do: "Task #{task_id}"

  defp resolve_stage(role, opts) do
    cond do
      opts[:stage] ->
        to_string(opts[:stage])

      role && role.stage ->
        TaskStage.label(role.stage)

      role && role.name ->
        role.name

      true ->
        "Unknown"
    end
  end

  defp calculate_duration(%DateTime{} = started_at, %DateTime{} = completed_at) do
    DateTime.diff(completed_at, started_at, :second)
  end

  defp calculate_duration(_started_at, _completed_at), do: nil
end
