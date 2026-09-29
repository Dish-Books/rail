defmodule Rail.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Each context supervises its own processes, so the tree lists the contexts and
    # the infrastructure they all share.
    children = [
      Rail.Vault,
      Rail.Repo,
      {Oban, Application.fetch_env!(:rail, Oban)},
      {Phoenix.PubSub, name: Rail.PubSub},
      {Task.Supervisor, name: Rail.TaskSupervisor},
      Rail.Tools,
      RailWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Rail.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Sandboxes keep running while Rail is down; this is when their conversations
  # will say it went.
  @impl true
  def prep_stop(state) do
    if Application.get_env(:rail, :adopt_on_boot, true), do: Rail.Tools.record_rail_stop()
    state
  end

  @impl true
  def config_change(changed, _new, removed) do
    RailWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
