defmodule Rail.Tools.Actions.RefreshUsage do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Agy
  alias Rail.Tools.Claude
  alias Rail.Tools.Schemas.Backend

  @probes %{claude: &Claude.probe/1, agy: &Agy.probe/1}

  # Every configured backend is probed, one per account, and a kind nothing
  # knows how to probe is left out.
  def refresh_usage do
    tasks =
      for %Backend{name: name} = backend <- Tools.list_backends(), probe = @probes[name] do
        {backend, Task.async(fn -> probe.(backend) end)}
      end

    {:ok, Enum.map(tasks, &await_usage/1)}
  end

  # The probes run in tasks, but the write stays here: the caller owns the
  # database connection. `usage_changeset/2` leaves the user's config alone.
  defp await_usage({backend, task}) do
    backend
    |> Backend.usage_changeset(Task.await(task, 35_000))
    |> Repo.update!()
  end
end
