defmodule Rail.Pipeline.Utils.PrepareWorktree do
  @moduledoc """
  Gets a task's worktree ready to work in: a slot of ports of its own, and the
  checkout itself.
  """

  import Ecto.Query

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @claim_attempts 5

  @doc """
  Claims `task` a worktree slot if it has none, then gets or creates its worktree.

  Returns `{:ok, task, worktree_path}` with the task as it now stands.
  """
  def prepare_worktree(%Project{} = project, %Task{} = task) do
    with {:ok, task} <- claim_slot(task, @claim_attempts),
         {:ok, worktree_path} <- Git.get_or_create_worktree(project, task) do
      {:ok, task, worktree_path}
    end
  end

  defp claim_slot(%Task{worktree_slot: slot} = task, _attempts) when is_integer(slot), do: {:ok, task}
  # coveralls-ignore-next-line (only reached by claims racing each other five times over)
  defp claim_slot(%Task{}, 0), do: {:error, :no_worktree_slot}

  # Slots are ports on this machine, so they are counted across every project;
  # two tasks claiming at once is settled by the unique index and a second look.
  defp claim_slot(%Task{} = task, attempts) do
    taken = MapSet.new(Repo.all(from t in Task, where: not is_nil(t.worktree_slot), select: t.worktree_slot))
    slot = Enum.find(Stream.iterate(0, &(&1 + 1)), &(not MapSet.member?(taken, &1)))

    case task |> Task.changeset(%{worktree_slot: slot}) |> Repo.update() do
      {:ok, task} ->
        {:ok, task}

      # coveralls-ignore-start (a claim racing another for the same slot, which a test cannot arrange)
      {:error, %Ecto.Changeset{}} ->
        claim_slot(task, attempts - 1)
        # coveralls-ignore-stop
    end
  end
end
