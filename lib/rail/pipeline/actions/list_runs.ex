defmodule Rail.Pipeline.Actions.ListRuns do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists runs, filtered and preloaded as `opts` asks.

  `:project_id` reaches through the task each run belongs to, so a caller showing
  one project's work asks for runs and gets exactly those. `:owner_user_id` reaches
  on to the task's issue and keeps the runs on issues that user owns.

  Runs on cleaned-up tasks are left out unless `include_cleaned_up: true`.
  """
  def list_runs(opts \\ []) do
    Run
    |> from(as: :run)
    |> join(:inner, [run: r], t in Task, on: t.id == r.task_id, as: :task)
    |> order_by(^Keyword.get(opts, :order_by, asc: :inserted_at))
    |> preload(^Keyword.get(opts, :preload, []))
    |> filter_project(opts[:project_id])
    |> filter_owner(opts[:owner_user_id])
    |> filter_cleaned_up(opts[:include_cleaned_up])
    |> Repo.all()
  end

  defp filter_project(query, project_id) when is_binary(project_id) do
    where(query, [task: t], t.project_id == ^project_id)
  end

  defp filter_project(query, _all_projects), do: query

  defp filter_owner(query, user_id) when is_binary(user_id) do
    query
    |> join(:inner, [task: t], i in assoc(t, :issue), as: :issue)
    |> where([issue: i], i.owner_user_id == ^user_id)
  end

  defp filter_owner(query, nil), do: query

  defp filter_cleaned_up(query, true), do: query
  defp filter_cleaned_up(query, _live_only), do: where(query, [task: t], is_nil(t.cleaned_up_at))
end
