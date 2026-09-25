defmodule Rail.Pipeline.Actions.ListTasks do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists tasks, filtered and preloaded as `opts` asks.

  `:owner_user_id` keeps the tasks whose issue that user owns, so an unowned issue's tasks drop out.
  Cleaned-up tasks are left out unless `include_cleaned_up: true`.
  """
  def list_tasks(opts \\ []) do
    Task
    |> from(as: :task)
    |> order_by(^Keyword.get(opts, :order_by, asc: :inserted_at))
    |> preload(^Keyword.get(opts, :preload, []))
    |> filter_project(opts[:project_id])
    |> filter_owner(opts[:owner_user_id])
    |> filter_stage(opts[:stage])
    |> filter_cleaned_up(opts[:include_cleaned_up])
    |> Repo.all()
  end

  defp filter_cleaned_up(query, true), do: query
  defp filter_cleaned_up(query, _live_only), do: where(query, [task: t], is_nil(t.cleaned_up_at))

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

  defp filter_stage(query, nil), do: query

  defp filter_stage(query, stage) when is_atom(stage) do
    where(query, [task: t], t.stage == ^stage)
  end
end
