defmodule Rail.Pipeline.Utils.RecordFixes do
  @moduledoc """
  Writes a fix round's commit onto what it fixed: each finding fixed in it with a note of the places it
  covered, those it left and why, and its test, and each other file it changed said in the conversation.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Records fix round `round`, committed as `sha` on `run`. `fixes` are `%{finding:, covered:, left:, test:}`
  and `others` `%{"path" => _, "reason" => _}`.
  """
  def record_fixes(%Task{} = task, %Run{} = run, round, sha, fixes, others) do
    now = DateTime.utc_now()

    for %{finding: finding, covered: covered, left: left, test: test} <- fixes do
      places =
        finding.places
        |> Enum.with_index(1)
        |> Enum.map(fn {place, n} ->
          case List.keyfind(left, n, 0) do
            {^n, reason} -> FindingPlace.leave_changeset(place, reason)
            nil -> place
          end
        end)

      note = %{
        round: round,
        kind: :fix,
        at: now,
        commit: sha,
        covered: Enum.map(covered, &FindingPlace.describe(Enum.at(finding.places, &1 - 1))),
        left: Enum.map(left, fn {n, reason} -> "#{FindingPlace.describe(Enum.at(finding.places, n - 1))}: #{reason}" end),
        test: "#{String.trim(test["file"])}: #{String.trim(test["name"])}"
      }

      finding
      |> Finding.note_changeset(%{status: :fixed, fixed_in: sha, note: note})
      |> Ecto.Changeset.put_embed(:places, places)
      |> Repo.update!()
    end

    lines =
      for %{"path" => path, "reason" => reason} <- others, do: "[rail] #{path} changed in fix round #{round}: #{reason}"

    if lines != [], do: Pipeline.append_run_events(run.id, nil, lines)
    Pipeline.broadcast_output_saved(task)
  end
end
