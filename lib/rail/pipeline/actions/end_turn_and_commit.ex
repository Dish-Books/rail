defmodule Rail.Pipeline.Actions.EndTurnAndCommit do
  @moduledoc """
  The `commit` tool, the engineer's and the Review lead's alike: ends the turn, then commits and sends the
  work on. At Review it is a fix round, refused until it accounts for every Fix finding and changed file.
  """

  import Rail.Pipeline.Utils.EndTurn
  import Rail.Pipeline.Utils.WithLiveTurn

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Ends `task`'s turn carried by `os_process` and commits what `arguments` describes: `{:ok, :committing}`
  once the turn is stopped, or `{:refused, text}` saying what to settle first while the turn goes on.
  """
  def end_turn_and_commit(%Task{} = task, %OsProcess{} = os_process, arguments) when is_map(arguments) do
    case with_live_turn(os_process, fn ->
           run = Run |> Repo.get!(os_process.run_id) |> Repo.preload(:role)
           task |> Repo.reload!() |> Repo.preload(:issue) |> accept(run, arguments)
         end) do
      :ended -> {:refused, "Refused, nothing committed again. This turn has already ended and handed its work to Rail."}
      result -> result
    end
  end

  defp accept(%Task{} = task, %Run{role: %Role{stage: role_stage}} = run, arguments) do
    cond do
      Task.role_stage(task.stage) != role_stage ->
        refused(
          "The task is at #{Task.stage_label(task.stage)}, so your work is no longer committed from this conversation."
        )

      not is_binary(arguments["message"]) or String.trim(arguments["message"]) == "" ->
        refused("`message` is required: one line saying what this change does, then the body.")

      task.is_updating_branch ->
        refused(
          "This turn is resolving a merge, and Rail commits the merge itself once you stop: `git add` each " <>
            "resolved file and end your turn without calling commit."
        )

      role_stage == :review_lead ->
        accept_round(task, run, arguments)

      not Git.worktree_dirty?(task.worktree_path) and run.ci_failure_streak == 0 ->
        refused(
          "Nothing in the worktree has changed. Make the change first, or say in your last message why there is nothing to do."
        )

      true ->
        commit(run, %{message: String.trim(arguments["message"])})
    end
  end

  defp accept_round(%Task{} = task, %Run{} = run, arguments) do
    outstanding = task |> Pipeline.list_findings() |> Enum.filter(&Finding.outstanding?/1) |> Map.new(&{&1.key, &1})
    listed = entries(arguments["findings"])
    others = entries(arguments["other_files"])
    changed = if Task.worktree_present?(task), do: Git.list_changed_paths(task.worktree_path), else: []

    with :ok <- check_listed(outstanding, listed),
         {:ok, fixes} <- check_fixes(outstanding, listed),
         :ok <- check_others(others),
         :ok <- check_changed(changed, run, fixes, others) do
      commit(run, %{message: String.trim(arguments["message"]), fixes: fixes, other_files: others})
    end
  end

  # After a CI failure, committing nothing is the agent asking for CI again.
  defp commit(%Run{} = run, attrs) do
    :ok =
      end_turn(run, fn ->
        case Pipeline.commit_work(Scope.for_system(), run, attrs) do
          {:ok, _run} -> :ok
          {:error, reason} -> {:error, "Could not commit: #{describe(reason)}"}
        end
      end)

    {:ok, :committing}
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp entries(entries) when is_list(entries), do: entries
  defp entries(_none), do: []

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
          place <- [Enum.at(finding.places, n - 1)],
          is_struct(place, FindingPlace),
          file = place.file,
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
end
