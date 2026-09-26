defmodule Rail.Triage do
  @moduledoc """
  Public context for triage: Slack threads in a project's connected channels,
  read by an agent that verifies each claim against the code and proposes a
  reply and an issue for a person to accept.

  It owns the Socket Mode connections events arrive on, one per workspace.
  """

  use Supervisor

  alias Rail.Triage.Actions

  @doc """
  Starts the registry and supervisor the Slack sockets run under, and the
  manager that opens one per workspace.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Rail.Triage.SocketRegistry},
      {DynamicSupervisor, name: Rail.Triage.SocketSupervisor, strategy: :one_for_one},
      Rail.Triage.SocketManager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defdelegate handle_slack_event(workspace, payload), to: Actions.HandleSlackEvent
  defdelegate triage_thread(thread), to: Actions.TriageThread
  defdelegate read_triage(thread), to: Actions.ReadTriage
  defdelegate sync_triage(thread, result, item_keys_in_scope), to: Actions.SyncTriage
  defdelegate get_triage_thread(scope, id), to: Actions.GetTriageThread
  defdelegate update_triage_draft(scope, item, attrs), to: Actions.UpdateTriageDraft
  defdelegate create_triage_issue(scope, item, attrs), to: Actions.CreateTriageIssue
  defdelegate post_triage_reply(scope, item, attrs), to: Actions.PostTriageReply
  defdelegate correct_triage_item(scope, item, attrs), to: Actions.CorrectTriageItem
  defdelegate dismiss_triage_thread(scope, thread), to: Actions.DismissTriageThread
  defdelegate retriage_thread(scope, thread), to: Actions.RetriageThread
  defdelegate list_triage_threads(opts \\ []), to: Actions.ListTriageThreads
  defdelegate count_triage_threads(opts), to: Actions.CountTriageThreads
end
