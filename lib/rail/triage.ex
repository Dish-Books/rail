defmodule Rail.Triage do
  @moduledoc """
  Public context for triage: Slack threads in a project's connected channels,
  read by an agent that verifies each claim against the code and drafts one
  reply, tickets and follow-ups for a person to send.

  It owns the Socket Mode connections events arrive on, one per workspace.
  """

  use Supervisor

  alias Rail.Triage.Actions

  @doc """
  Starts the registry and supervisor the Slack sockets run under, the manager
  that opens one per workspace, and the runner that triages threads.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Rail.Triage.SocketRegistry},
      {DynamicSupervisor, name: Rail.Triage.SocketSupervisor, strategy: :one_for_one},
      Rail.Triage.SocketManager,
      Rail.Triage.Runner
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defdelegate handle_slack_event(workspace, payload), to: Actions.HandleSlackEvent
  defdelegate backfill_slack_workspace(workspace), to: Actions.BackfillSlackWorkspace
  defdelegate get_slack_socket_status(workspace), to: Actions.GetSlackSocketStatus
  defdelegate triage_thread(thread), to: Actions.TriageThread
  defdelegate read_triage(thread), to: Actions.ReadTriage
  defdelegate sync_triage(thread, result, started_at), to: Actions.SyncTriage
  defdelegate get_triage_thread(scope, id), to: Actions.GetTriageThread
  defdelegate get_triage_image(scope, message_id, file_id), to: Actions.GetTriageImage
  defdelegate send_triage_chat(scope, thread, attrs), to: Actions.SendTriageChat
  defdelegate update_triage_reply(scope, thread, attrs), to: Actions.UpdateTriageReply
  defdelegate update_triage_item(scope, item, attrs), to: Actions.UpdateTriageItem
  defdelegate send_triage_reply(scope, thread), to: Actions.SendTriageReply
  defdelegate dismiss_triage_thread(scope, thread), to: Actions.DismissTriageThread
  defdelegate list_triage_threads(opts \\ []), to: Actions.ListTriageThreads
  defdelegate count_triage_threads(opts), to: Actions.CountTriageThreads
  defdelegate create_forwarded_thread(scope, conversation, items), to: Actions.CreateForwardedThread
end
