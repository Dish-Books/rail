defmodule Rail.Pipeline.Actions.EndTurnAndCommitFixes do
  @moduledoc """
  The Review lead's `commit_fixes`: ends the turn it is called in, then commits the fix round as one commit
  labeled Fix round N, notes on each finding what fixed it, and sends the round on, through CI on the Review
  run or pushed, after which the next round starts.

  It refuses a round that leaves out a finding ruled Fix, lists one without a place or a test, leaves one of
  its places unaccounted for, or holds a changed file nothing it lists explains: a file the fix touched with
  no finding behind it is a change the human never ruled on, so it needs a reason the human can read.
  """

  import Rail.Pipeline.Utils.CiPassed
  import Rail.Pipeline.Utils.CommitMessage
  import Rail.Pipeline.Utils.EndTurn
  import Rail.Pipeline.Utils.OpenPullRequest
  import Rail.Pipeline.Utils.StartCi
  import Rail.Pipeline.Utils.StartNextRound
  import Rail.Pipeline.Utils.WithLiveTurn

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Ends `task`'s Review lead turn, carried by `os_process`, and commits the round `arguments` describes:
  `{:ok, :committing}` once the turn is stopped, or `{:refused, text}` saying what to settle first.
  """
  def end_turn_and_commit_fixes(%Task{} = task, %OsProcess{} = os_process, arguments) do
    case with_live_turn(os_process, fn ->
           task |> Repo.reload!() |> Repo.preload(:issue) |> accept(Repo.get!(Run, os_process.run_id), arguments)
         end) do
      :ended -> {:refused, "Refused, nothing committed again. This turn has already ended and handed the round to Rail."}
      result -> result
    end
  end

  defp accept(%Task{} = task, %Run{} = run, arguments) when is_map(arguments) do
    outstanding = task |> Pipeline.list_findings() |> Enum.filter(&Finding.outstanding?/1) |> Map.new(&{&1.key, &1})
    listed = entries(arguments["findings"])
    others = entries(arguments["other_files"])
    changed = if Task.worktree_present?(task), do: Git.list_changed_paths(task.worktree_path), else: []

    with :ok <- check_message(arguments["message"]),
         :ok <- check_listed(outstanding, listed),
         {:ok, fixes} <- check_fixes(outstanding, listed),
         :ok <- check_others(others),
         :ok <- check_changed(changed, run, fixes, others) do
      round = max(length(Pipeline.read_review(task)), 1)
      message = String.trim(arguments["message"])
      :ok = end_turn(run, fn -> commit_round(task, run, round, message, fixes, others) end)
      {:ok, :committing}
    end
  end

  defp accept(%Task{}, %Run{}, _arguments), do: refused("commit_fixes needs a `message` and the `findings` it fixed.")

  defp entries(entries) when is_list(entries), do: entries
  defp entries(_none), do: []

  defp check_message(message) when is_binary(message) do
    if String.trim(message) == "",
      do: refused("`message` is required: one line saying what this round does, then the body."),
      else: :ok
  end

  defp check_message(_none), do: refused("`message` is required: one line saying what this round does, then the body.")

  defp check_listed(outstanding, listed) do
    keys = for %{"key" => key} <- listed, do: key
    missing = outstanding |> Map.keys() |> Enum.reject(&(&1 in keys)) |> Enum.sort()
    unknown = Enum.reject(keys, &Map.has_key?(outstanding, &1))

    cond do
      Enum.any?(listed, &(not match?(%{"key" => key} when is_binary(key), &1))) ->
        refused("every entry in `findings` names its finding by `key`.")

      missing != [] ->
        refused("the round leaves out #{Enum.join(missing, ", ")}, ruled Fix. List every finding ruled Fix.")

      unknown != [] ->
        refused("#{Enum.join(unknown, ", ")} is not a finding ruled Fix and still to fix.")

      true ->
        :ok
    end
  end

  # Every place a finding's rule applies is covered by the fix or left with a reason.
  defp check_fixes(outstanding, listed) do
    Enum.reduce_while(listed, {:ok, []}, fn %{"key" => key} = entry, {:ok, fixes} ->
      case fix(Map.fetch!(outstanding, key), entry) do
        {:ok, fix} -> {:cont, {:ok, List.insert_at(fixes, -1, fix)}}
        {:refused, text} -> {:halt, {:refused, text}}
      end
    end)
  end

  defp fix(%Finding{key: key, places: places} = finding, entry) do
    numbers = 1..max(length(places), 1)//1
    covered = for n <- entries(entry["covered"]), is_integer(n), n in numbers, uniq: true, do: n

    left =
      for %{"place" => n, "reason" => reason} <- entries(entry["left"]),
          is_integer(n),
          is_binary(reason),
          do: {n, String.trim(reason)}

    unaccounted = Enum.reject(numbers, &(&1 in covered or List.keymember?(left, &1, 0)))

    cond do
      covered == [] ->
        refused("#{key} is listed without a place: give the numbers of the places its fix covers in `covered`.")

      not test?(entry["test"]) ->
        refused("#{key} is listed without a test: give the `file` and `name` of the test that failed first.")

      Enum.any?(left, fn {_n, reason} -> reason == "" end) ->
        refused("#{key} leaves a place with no reason. Say why in `reason`.")

      places != [] and unaccounted != [] ->
        refused(
          "#{key} leaves place #{Enum.join(unaccounted, ", ")} unaccounted for: cover it, or list it in `left` " <>
            "with the reason the fix leaves it."
        )

      true ->
        {:ok, %{finding: finding, covered: covered, left: left, test: entry["test"]}}
    end
  end

  defp test?(%{"file" => file, "name" => name}) when is_binary(file) and is_binary(name),
    do: String.trim(file) != "" and String.trim(name) != ""

  defp test?(_none), do: false

  defp check_others(others) do
    if Enum.all?(others, &match?(%{"path" => path, "reason" => reason} when is_binary(path) and is_binary(reason), &1)) and
         Enum.all?(others, &(String.trim(&1["reason"]) != "")),
       do: :ok,
       else: refused("each entry in `other_files` needs the `path` and the `reason` it changed.")
  end

  # After a CI failure, a round with nothing changed is the lead asking for CI again.
  defp check_changed([], %Run{ci_failure_streak: streak}, _fixes, _others) when streak > 0, do: :ok

  defp check_changed([], %Run{}, _fixes, _others),
    do: refused("nothing in the worktree has changed. Have the engineer make the fixes first.")

  defp check_changed(changed, %Run{}, fixes, others) do
    explained =
      MapSet.new(
        for(
          %{finding: finding, covered: covered} <- fixes,
          n <- covered,
          file = Enum.at(finding.places, n - 1).file,
          do: file
        ) ++
          for(%{test: %{"file" => file}} <- fixes, do: String.trim(file)) ++
          for(%{"path" => path} <- others, do: String.trim(path))
      )

    case Enum.reject(changed, &MapSet.member?(explained, &1)) do
      [] ->
        :ok

      unexplained ->
        refused(
          "#{Enum.join(unexplained, ", ")} changed, and no place, test or reason you listed explains it. " <>
            "List it in `other_files` with why it changed, or undo it."
        )
    end
  end

  defp refused(text), do: {:refused, "Refused, nothing committed. " <> text}

  # The run is read again, since stopping the turn settled it after this call read it.
  defp commit_round(%Task{} = task, %Run{} = run, round, message, fixes, others) do
    task = Repo.preload(task, [:issue, :project], force: true)
    run = Repo.get!(Run, run.id)

    scope = Scope.for_system()

    committed =
      if Git.worktree_dirty?(task.worktree_path),
        do: Git.commit_worktree(scope, task, commit_message(task, message, "Fix round #{round}")),
        else: {:ok, nil}

    case committed do
      {:ok, sha} ->
        if sha, do: record(task, run, round, sha, fixes, others)
        send_on(scope, task, %{run | task: task})

      {:error, reason} ->
        {:error, "Could not commit fix round #{round}: #{inspect(reason)}"}
    end
  end

  defp record(%Task{} = task, %Run{} = run, round, sha, fixes, others) do
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

  # A commit CI has not passed is not pushed: CI's finish pushes it and starts the next round.
  defp send_on(%Scope{} = scope, %Task{project: %Project{ci_command: command}} = task, %Run{} = run) do
    if command in [nil, ""] or ci_passed?(task) do
      with :ok <- Git.push_branch(scope, task) do
        _task = open_pull_request(task, run)
        start_next_round(run, "it was pushed")
      end
    else
      case start_ci(run) do
        {:ok, _os_process} -> :ok
        {:error, %Run{error: error}} -> {:error, error}
      end
    end
  end
end
