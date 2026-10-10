defmodule Rail.Pipeline.Utils.PrepareTurn do
  @moduledoc """
  Readies a task's worktree for an engineer's or Review lead's turn: the default branch fetched from
  `origin`, so the agent can tell whether its branch is behind, and the ticket owner's identity and signing
  key written in, so the agent's own commits are theirs. Neither failing stops the turn: it is said in the
  conversation instead.
  """

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Fetches the default branch and sets the commit identity for `run`'s next turn. Returns what the turn's
  prompt opens with: a line saying the branch is behind the default branch, or `""` when it is not.
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

      behind(task, base)
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
          "to date with it, by merge or rebase, before anything else.\n\n"
  end

  # One line, since a log line that wraps reads its tail as the agent's words.
  defp say(%Run{id: run_id}, text) do
    _logged = Pipeline.append_run_events(run_id, nil, ["[rail] " <> (text |> String.split() |> Enum.join(" "))])
    :ok
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
