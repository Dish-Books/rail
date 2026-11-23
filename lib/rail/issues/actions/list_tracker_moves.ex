defmodule Rail.Issues.Actions.ListTrackerMoves do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.LinearFileCopy
  alias Rail.Issues.Workers.CopyLinearFile
  alias Rail.Issues.Workers.MoveToLocalTracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @active ["available", "scheduled", "executing", "retryable"]
  @unexpected "The move stopped unexpectedly, before it could say why."

  @doc """
  Where each project's latest move into Rail stands, as `{:ok, map}` by project id: `:moved`, `:moving`,
  `{:copying, settled, total}` while its files are copied, or `{:stopped, sentence}`.
  Projects with no move are left out, as is a finished move whose project is still on Linear.
  """
  def list_tracker_moves(%Scope{}, projects) when is_list(projects) do
    trackers = Map.new(projects, &{&1.id, &1.tracker})
    ids = Enum.map(projects, & &1.id)
    jobs = latest_moves(projects)
    copying = copying_projects(projects)
    files = file_counts(ids)
    failures = first_failures(ids)

    moves =
      for id <- ids,
          move =
            calculate_move(trackers[id], %{
              job: jobs[id],
              copying?: MapSet.member?(copying, id),
              files: files[id],
              failure: failures[id]
            }),
          into: %{},
          do: {id, move}

    {:ok, moves}
  end

  # The sentence comes before the job's state, since Oban marks the job only after the worker returns. A run that
  # stopped is newer than any file that failed, since files are queued only by a run that went on to finish.
  defp calculate_move(:local, _move), do: :moved

  defp calculate_move(_linear, %{job: {_state, %{"failure" => sentence}}}) when is_binary(sentence),
    do: {:stopped, sentence}

  defp calculate_move(_linear, %{job: {state, _meta}} = move) when state in @active, do: moving(move.files)
  defp calculate_move(_linear, %{copying?: true} = move), do: moving(move.files)

  defp calculate_move(_linear, %{failure: failure, files: files}) when is_binary(failure),
    do: {:stopped, "#{failure} #{kept(files)}"}

  defp calculate_move(_linear, %{files: %{pending: pending} = files}) when pending > 0,
    do: {:stopped, "#{@unexpected} #{kept(files)}"}

  defp calculate_move(_linear, %{job: {"discarded", _meta}}), do: {:stopped, @unexpected}
  defp calculate_move(_linear, _move), do: nil

  defp moving(%{settled: settled, total: total}), do: {:copying, settled, total}
  defp moving(nil), do: :moving

  defp kept(%{settled: settled, total: total}),
    do: "#{settled} of #{total} files are copied, and trying again copies only the rest."

  defp latest_moves(projects) do
    query =
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(MoveToLocalTracker),
        where: ^matches(projects),
        distinct: fragment("?->>'project_id'", j.args),
        order_by: [asc: fragment("?->>'project_id'", j.args), desc: j.id],
        select: {fragment("?->>'project_id'", j.args), {j.state, j.meta}}
      )

    Map.new(Repo.all(query))
  end

  defp copying_projects(projects) do
    query =
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(CopyLinearFile),
        where: j.state in @active,
        where: ^matches(projects),
        distinct: true,
        select: fragment("?->>'project_id'", j.args)
      )

    MapSet.new(Repo.all(query))
  end

  # One containment test a project, so the lookup runs on the args index.
  defp matches(projects) do
    Enum.reduce(projects, dynamic(false), fn %Project{id: id}, matches ->
      dynamic([j], ^matches or fragment("? @> ?", j.args, ^%{project_id: id}))
    end)
  end

  defp file_counts(ids) do
    query =
      from(c in LinearFileCopy,
        where: c.project_id in ^ids,
        group_by: c.project_id,
        select:
          {c.project_id,
           %{
             total: count(c.id),
             settled: filter(count(c.id), c.state in [:copied, :gone]),
             pending: filter(count(c.id), c.state == :pending)
           }}
      )

    Map.new(Repo.all(query))
  end

  defp first_failures(ids) do
    query =
      from(c in LinearFileCopy,
        where: c.project_id in ^ids and c.state == :failed,
        distinct: c.project_id,
        order_by: [asc: c.project_id, asc: c.updated_at],
        select: {c.project_id, c.error}
      )

    Map.new(Repo.all(query))
  end
end
