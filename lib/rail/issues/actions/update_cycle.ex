defmodule Rail.Issues.Actions.UpdateCycle do
  @moduledoc """
  A person's edit of a Rail-tracked cycle's dates, which moves every later cycle by as many days as its end moved.
  """

  import Rail.Issues.Utils.LockCycles

  alias Rail.Issues.Schemas.Cycle
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Writes `attrs` to the cycle `cycle_id` names in `project` and shifts the cycles after it, all or nothing, then
  broadcasts `{:cycles_changed, project_id}` on `"cycles"`. Returns the cycle as written, `{:error, changeset}` for
  dates the edit refuses, or `{:error, :not_found}`.
  """
  def update_cycle(%Scope{} = scope, %Project{id: project_id}, cycle_id, attrs) do
    written =
      if Scope.can_access_project?(scope, project_id) do
        Repo.transaction(fn ->
          case Enum.split_while(lock_cycles(project_id), &(&1.id != cycle_id)) do
            {_earlier, [cycle | later]} -> write_dates(Cycle.dates_changeset(cycle, attrs, Date.utc_today()), later)
            {_earlier, []} -> Repo.rollback(:not_found)
          end
        end)
      else
        {:error, :not_found}
      end

    with {:ok, {cycle, changed}} <- written do
      if changed, do: Phoenix.PubSub.broadcast(Rail.PubSub, "cycles", {:cycles_changed, project_id})
      {:ok, cycle}
    end
  end

  # Rows are written one at a time in an order that never puts two on the same day, since the overlap check is
  # immediate: furthest first when the end moves later, the edited one first when it moves earlier.
  defp write_dates(%Ecto.Changeset{valid?: false} = changeset, _later), do: Repo.rollback(%{changeset | action: :update})

  defp write_dates(%Ecto.Changeset{data: cycle} = changeset, later) do
    shift = Date.diff(Ecto.Changeset.get_field(changeset, :ends_on), cycle.ends_on)

    shifted =
      for later_cycle <- later,
          do:
            Ecto.Changeset.change(later_cycle,
              starts_on: Date.add(later_cycle.starts_on, shift),
              ends_on: Date.add(later_cycle.ends_on, shift)
            )

    written =
      if shift > 0 do
        shifted |> Enum.reverse() |> Enum.each(&Repo.update!/1)
        Repo.update(changeset)
      else
        with {:ok, written} <- Repo.update(changeset) do
          Enum.each(shifted, &Repo.update!/1)
          {:ok, written}
        end
      end

    case written do
      {:ok, written} -> {written, changeset.changes != %{}}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
