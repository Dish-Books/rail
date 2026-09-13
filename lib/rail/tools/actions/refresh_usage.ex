defmodule Rail.Tools.Actions.RefreshUsage do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Agy
  alias Rail.Tools.Claude
  alias Rail.Tools.Schemas.Backend

  def refresh_usage do
    claude = start_probe(:claude, &Claude.probe/1)
    agy = start_probe(:agy, &Agy.probe/1)

    {:ok, Enum.map(claude ++ agy, &await_usage/1)}
  end

  # A backend the user has not configured has nothing to probe, and no reason to
  # stop the ones that do.
  defp start_probe(name, probe) do
    case Tools.get_backend(name) do
      {:ok, backend} -> [{backend, Task.async(fn -> probe.(backend) end)}]
      {:error, :backend_not_found} -> []
    end
  end

  # The probes run in tasks, but the write stays here: the caller owns the
  # database connection. `usage_changeset/2` leaves the user's config alone.
  defp await_usage({backend, task}) do
    backend
    |> Backend.usage_changeset(Task.await(task, 35_000))
    |> Repo.update!()
  end
end
