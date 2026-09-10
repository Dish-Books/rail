defmodule Rail.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Rail.Vault,
      Rail.Repo,
      {Phoenix.PubSub, name: Rail.PubSub},
      {Registry, keys: :unique, name: Rail.Runs.FollowerRegistry},
      Rail.Runs.FollowerSupervisor,
      Rail.Runs.Boot,
      {Task.Supervisor, name: Rail.TaskSupervisor},
      Rail.Backends.RefreshServer,
      Rail.Pipeline.Dispatcher,
      Rail.Periodic,
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
end
