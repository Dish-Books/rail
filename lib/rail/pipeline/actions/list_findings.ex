defmodule Rail.Pipeline.Actions.ListFindings do
  @moduledoc """
  The findings raised against a task, code and screen alike, ordered by what each one is so that no ruling
  or fix ever moves one and the reader keeps their place.

  The newest round comes first, a finding carried into a round sitting after those raised in it, then worst
  first and oldest first. Severity's rank comes from the schema's own list, since `Ecto.Enum` stores it as text.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Lists every finding on `task`, newest round first, worst first, oldest first, with `id` breaking any tie.
  """
  def list_findings(%Task{id: task_id}) do
    rank = Finding.severities() |> Enum.with_index() |> Map.new()

    from(f in Finding, where: f.task_id == ^task_id)
    |> Repo.all()
    # A `DateTime` compares field by field in term order, not by time.
    |> Enum.sort_by(
      &{-(&1.carried_round || &1.round), if(&1.carried_round, do: 1, else: 0), Map.fetch!(rank, &1.severity),
       DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}
    )
  end
end
