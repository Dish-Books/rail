defmodule Rail.Issues.Actions.ListTrackerMoves do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Workers.MoveToLocalTracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @unexpected "The move stopped unexpectedly, before it could say why."

  @doc """
  Where each project's latest move into Rail stands, as `{:ok, map}` by project id: `:moved`, `:moving`, or `{:stopped, sentence}`.
  Projects with no move are left out, as is a finished move whose project is still on Linear.
  """
  def list_tracker_moves(%Scope{}, projects) when is_list(projects) do
    trackers = Map.new(projects, &{&1.id, &1.tracker})

    # One containment test a project, so the lookup runs on the args index.
    matches =
      Enum.reduce(projects, dynamic(false), fn %Project{id: id}, matches ->
        dynamic([j], ^matches or fragment("? @> ?", j.args, ^%{project_id: id}))
      end)

    query =
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(MoveToLocalTracker),
        where: ^matches,
        distinct: fragment("?->>'project_id'", j.args),
        order_by: [asc: fragment("?->>'project_id'", j.args), desc: j.id],
        select: {fragment("?->>'project_id'", j.args), j.state, j.meta}
      )

    moves =
      for {project_id, state, meta} <- Repo.all(query),
          move = calculate_move(trackers[project_id], state, meta),
          into: %{},
          do: {project_id, move}

    {:ok, moves}
  end

  # The sentence comes before the job's state, since Oban marks the job only after the worker returns.
  defp calculate_move(:local, _state, _meta), do: :moved
  defp calculate_move(_linear, _state, %{"failure" => sentence}) when is_binary(sentence), do: {:stopped, sentence}

  defp calculate_move(_linear, state, _meta) when state in ["available", "scheduled", "executing", "retryable"],
    do: :moving

  defp calculate_move(_linear, "discarded", _meta), do: {:stopped, @unexpected}
  defp calculate_move(_linear, _completed_or_cancelled, _meta), do: nil
end
