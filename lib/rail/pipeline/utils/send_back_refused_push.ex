defmodule Rail.Pipeline.Utils.SendBackRefusedPush do
  @moduledoc """
  Hands a push Rail would not make back to the agent whose turn committed it, as a CI failure goes back:
  the branch rewrote commits already pushed, which the agents may not do, or someone pushed to it outside
  Rail. Merging `origin/<branch>` in settles either, and the turn that does hands the branch over again.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Resumes `run`'s agent on why its branch was not pushed, `reason` being `:history_rewritten` or
  `:pushed_outside_rail`. Returns the run as it now stands.
  """
  def send_back_refused_push(%Run{task: %Task{worktree_name: branch}, role: %Role{} = role} = run, reason) do
    Pipeline.append_run_events(run.id, nil, ["[rail] #{said(reason, branch)} It went back to the #{agent(role)}."])

    {:ok, briefed} =
      run
      |> Run.changeset(%{pending_answer: note(reason, branch, role), status: :running, error: nil})
      |> Repo.update()

    # Each turn's system prompt is the one it is spawned with, so it is read as the repo has it now.
    {:ok, role} = Roles.get_role(id: run.role_id)

    case resume(%{briefed | task: run.task, role: role}) do
      {:ok, %OsProcess{run: %Run{} = resumed}} ->
        resumed

      {:error, {:spawn_failed, _reason, %Run{} = failed}} ->
        failed

      {:error, :dispatch_disabled} ->
        {:ok, stopped} =
          briefed
          |> Run.changeset(%{status: :finished, error: "Dispatch is off, so the #{agent(role)} was not resumed."})
          |> Repo.update()

        %{stopped | task: run.task, role: run.role}
    end
  end

  defp resume(%Run{role: %Role{stage: :review_lead}} = run), do: Pipeline.start_review_run(run)
  defp resume(%Run{} = run), do: Pipeline.start_engineer_run(run)

  defp said(:history_rewritten, branch),
    do: "The branch rewrote commits already pushed to origin/#{branch}, so Rail did not push it."

  defp said(:pushed_outside_rail, branch),
    do: "Someone pushed to origin/#{branch} outside Rail, so Rail did not push over it."

  defp note(reason, branch, role) do
    "#{said(reason, branch)} #{why(reason)} #{merge(role)} `origin/#{branch}`, which Rail has just fetched, " <>
      "into the branch so it holds every commit pushed, resolving any conflicts the way both sides meant " <>
      "them, commit, and end your turn: Rail hands the branch over again then."
  end

  defp why(:history_rewritten),
    do: "A rebase, an amend or a reset of a pushed commit rewrites history, which is never done here."

  defp why(:pushed_outside_rail), do: "Those commits are someone's work, so they are kept."

  defp merge(%Role{stage: :review_lead}), do: "Have the engineer merge"
  defp merge(%Role{}), do: "Merge"

  defp agent(%Role{stage: :review_lead}), do: "Review lead"
  defp agent(%Role{}), do: "engineer"
end
