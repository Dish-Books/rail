defmodule Rail.Pipeline.Utils.PrepareTurn do
  @moduledoc """
  Readies a task's worktree for an engineer's or Review lead's turn: the default branch fetched from
  `origin`, so the agent can tell whether its branch is behind, the task's own branch checked against what
  was pushed to it, and the ticket owner's identity and signing key written in, so the agent's own commits
  are theirs. Nothing failing stops the turn: it is said in the conversation instead.
  """

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Fetches the default branch and sets the commit identity for `run`'s next turn. Returns what the turn's
  prompt opens with: a line for each thing the branch must merge in before Rail can push it, or `""`.
  """
  def prepare_turn(%Run{task: %Task{} = task} = run) do
    %Project{default_branch: base} = project = Repo.get!(Project, task.project_id)

    if Task.worktree_present?(task) do
      with {:error, reason} <- Git.fetch_default_branch(project, task.worktree_path) do
        say(
          run,
          "Could not fetch origin/#{base} before this turn, so the copy fetched last is what the branch is checked against: #{describe(reason)}"
        )
      end

      with {:error, reason} <- Git.set_commit_identity(task) do
        say(run, "Could not set who this turn commits as, so its commits may not be signed: #{reason}")
      end

      behind(task, base) <> pushed(task)
    else
      ""
    end
  end

  # The brief says to check every turn, but a resumed turn is sent only its message, so the turn that
  # finds the branch behind is told so at the top.
  defp behind(%Task{worktree_path: worktree_path}, base) do
    if Git.up_to_date_with?(worktree_path, base),
      do: "",
      else:
        "Rail fetched origin/#{base} as this turn started, and the branch is behind it: bring the branch up " <>
          "to date with it, by merging it in, before anything else.\n\n"
  end

  # Rail never pushes over the remote branch, so what was pushed to it that the branch lacks is merged in first,
  # rather than found when Rail goes to push at the end of the turn.
  defp pushed(%Task{worktree_name: branch} = task) do
    case Git.check_push(task) do
      :ok ->
        ""

      {:error, :pushed_outside_rail} ->
        "Someone pushed to origin/#{branch} outside Rail, and the branch does not have those commits: merge " <>
          "origin/#{branch} in before anything else, so Rail can push the branch when this turn ends.\n\n"

      {:error, :history_rewritten} ->
        "The branch has rewritten commits already pushed to origin/#{branch}, which Rail never pushes over: " <>
          "merge origin/#{branch} in before anything else, so Rail can push the branch when this turn ends.\n\n"
    end
  end

  # One line, since a log line that wraps reads its tail as the agent's words.
  defp say(%Run{id: run_id}, text) do
    _logged = Pipeline.append_run_events(run_id, nil, ["[rail] " <> (text |> String.split() |> Enum.join(" "))])
    :ok
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
