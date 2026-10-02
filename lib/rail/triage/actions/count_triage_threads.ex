defmodule Rail.Triage.Actions.CountTriageThreads do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Triage.Schemas.Thread

  @doc """
  How many threads are in each status, across every project unless
  `:project_id` names one or a list, or in the channels `:slack_channel_id` lists.

  With `group_by: :slack_channel_id` it is instead how many threads each
  channel has, leaving out the channels with none.
  """
  def count_triage_threads(opts) when is_list(opts) do
    query =
      Thread
      |> filter_project(opts[:project_id])
      |> then(&if(ids = opts[:slack_channel_id], do: where(&1, [t], t.slack_channel_id in ^ids), else: &1))

    count(query, opts[:group_by])
  end

  defp count(query, :slack_channel_id) do
    query
    |> group_by([t], t.slack_channel_id)
    |> select([t], {t.slack_channel_id, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp count(query, nil) do
    counts = query |> group_by([t], t.status) |> select([t], {t.status, count(t.id)}) |> Repo.all() |> Map.new()
    Map.new(Thread.statuses(), &{&1, Map.get(counts, &1, 0)})
  end

  defp filter_project(query, nil), do: query
  defp filter_project(query, project_ids) when is_list(project_ids), do: where(query, [t], t.project_id in ^project_ids)
  defp filter_project(query, project_id), do: where(query, [t], t.project_id == ^project_id)
end
