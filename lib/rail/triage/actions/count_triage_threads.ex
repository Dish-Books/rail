defmodule Rail.Triage.Actions.CountTriageThreads do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Triage.Schemas.Thread

  @doc """
  How many threads are in each status, across every project unless
  `:project_id` names one, or in one channel when `:slack_channel_id` does.
  """
  def count_triage_threads(opts) when is_list(opts) do
    counts =
      Thread
      |> then(&if(project_id = opts[:project_id], do: where(&1, [t], t.project_id == ^project_id), else: &1))
      |> then(&if(channel_id = opts[:slack_channel_id], do: where(&1, [t], t.slack_channel_id == ^channel_id), else: &1))
      |> group_by([t], t.status)
      |> select([t], {t.status, count(t.id)})
      |> Repo.all()
      |> Map.new()

    Map.new(Thread.statuses(), &{&1, Map.get(counts, &1, 0)})
  end
end
