defmodule Rail.Triage.SocketManager do
  @moduledoc """
  Keeps one `Rail.Triage.SlackSocket` open for every Slack workspace with an
  app-level token, and restarts a workspace's socket when its settings change.
  Turned off with `config :rail, :slack_socket, false`.
  """
  use GenServer

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Triage.SlackSocket

  @doc """
  Starts the manager unless sockets are switched off. Takes `:enabled` to
  override the config, `:supervisor` to start sockets under, and `:backoff`
  for each socket.
  """
  def start_link(opts \\ []) do
    if Keyword.get(opts, :enabled, Application.get_env(:rail, :slack_socket, true)) do
      GenServer.start_link(__MODULE__, opts)
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Rail.PubSub, "slack_workspaces")
    {:ok, Map.new(Keyword.take(opts, [:supervisor, :backoff])), {:continue, :start_all}}
  end

  @impl true
  def handle_continue(:start_all, state) do
    Enum.each(Projects.list_slack_workspaces(), &start(&1, state))
    {:noreply, state}
  end

  @impl true
  def handle_info({:slack_workspace_changed, id}, state) do
    with [{pid, _value}] <- Registry.lookup(Rail.Triage.SocketRegistry, id) do
      DynamicSupervisor.terminate_child(supervisor(state), pid)
    end

    with {:ok, workspace} <- Projects.get_slack_workspace(id: id), do: start(workspace, state)

    {:noreply, state}
  end

  defp start(%SlackWorkspace{app_token: token} = workspace, state) when is_binary(token) and token != "" do
    opts = [workspace: workspace, backoff: Map.get(state, :backoff, 1_000)]
    DynamicSupervisor.start_child(supervisor(state), {SlackSocket, opts})
  end

  defp start(%SlackWorkspace{}, _state), do: :ignore

  defp supervisor(state), do: Map.get(state, :supervisor, Rail.Triage.SocketSupervisor)
end
