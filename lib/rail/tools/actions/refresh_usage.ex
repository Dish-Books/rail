defmodule Rail.Tools.Actions.RefreshUsage do
  @moduledoc false

  import Rail.Tools.Utils.AnnounceLostSession

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Claude
  alias Rail.Tools.Schemas.Backend

  # Every configured backend is probed, one per account.
  def refresh_usage do
    tasks =
      for %Backend{} = backend <- Tools.list_backends() do
        {backend, Task.async(fn -> Claude.probe(backend) end)}
      end

    {:ok, Enum.map(tasks, &await_usage/1)}
  end

  # The probes run in tasks, but the write stays here: the caller owns the
  # database connection. `usage_changeset/2` leaves the user's config alone.
  defp await_usage({backend, task}) do
    attrs = task |> Task.await(35_000) |> track_session(backend)
    refreshed = backend |> Backend.usage_changeset(attrs) |> Repo.update!()
    if is_nil(backend.session_lost_at) and refreshed.session_lost_at, do: announce_lost_session(refreshed)
    refreshed
  end

  # Signing out on purpose writes the row itself, so a probe that finds a ready
  # backend signed out is one nobody signed out. One found signed in again has
  # been signed in again, so its runs go on.
  defp track_session(%{status: :signed_out} = attrs, %Backend{status: :ready}),
    do: Map.put(attrs, :session_lost_at, DateTime.utc_now())

  defp track_session(%{status: :ready} = attrs, %Backend{}), do: Map.put(attrs, :session_lost_at, nil)

  defp track_session(attrs, _backend), do: attrs
end
