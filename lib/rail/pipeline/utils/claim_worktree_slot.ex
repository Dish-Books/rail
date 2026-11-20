defmodule Rail.Pipeline.Utils.ClaimWorktreeSlot do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @claim_attempts 5

  @doc """
  Claims `task` the lowest worktree slot no task in any project holds, unless it holds one already. Returns
  `{:ok, task}` with the slot, or `{:error, :no_worktree_slot}` once five claims in a row lose the race for one.
  """
  def claim_worktree_slot(%Task{} = task), do: claim(task, @claim_attempts)

  defp claim(%Task{worktree_slot: slot} = task, _attempts) when is_integer(slot), do: {:ok, task}
  # coveralls-ignore-next-line (only reached by claims racing each other five times over)
  defp claim(%Task{}, 0), do: {:error, :no_worktree_slot}

  # Slots are ports on this machine, so they are counted across every project;
  # two tasks claiming at once is settled by the unique index and a second look.
  defp claim(%Task{} = task, attempts) do
    taken = MapSet.new(Repo.all(from t in Task, where: not is_nil(t.worktree_slot), select: t.worktree_slot))
    slot = Enum.find(Stream.iterate(0, &(&1 + 1)), &(not MapSet.member?(taken, &1)))

    case task |> Task.changeset(%{worktree_slot: slot}) |> Repo.update() do
      {:ok, task} ->
        {:ok, task}

      # coveralls-ignore-start (a claim racing another for the same slot, which a test cannot arrange)
      {:error, %Ecto.Changeset{}} ->
        claim(task, attempts - 1)
        # coveralls-ignore-stop
    end
  end
end
