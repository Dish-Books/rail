defmodule Rail.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Rail.Vault,
        Rail.Repo
      ] ++
        livesync_child() ++
        [
          {Phoenix.PubSub, name: Rail.PubSub},
          {Registry, keys: :unique, name: Rail.Runs.FollowerRegistry},
          Rail.Runs.FollowerSupervisor,
          Rail.Runs.Boot,
          {Task.Supervisor, name: Rail.TaskSupervisor},
          Rail.Backends.RefreshServer,
          Rail.Pipeline.TaskActionRunner,
          RailWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: Rail.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RailWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp livesync_child do
    if Application.get_env(:rail, :enable_livesync, true) and logical_replication?() do
      [{LiveSync, [repo: Rail.Repo, otp_app: :rail]}]
    else
      []
    end
  end

  defp logical_replication? do
    case Rail.Repo.query("show wal_level;") do
      {:ok, %Postgrex.Result{rows: [["logical"]]}} -> true
      _other -> false
    end
  rescue
    _error -> false
  end
end
