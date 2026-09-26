defmodule Rail.Triage.Actions.DismissTriageThread do
  @moduledoc false

  import Rail.Triage.Utils.SettleThread

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Thread

  @doc """
  Finishes a thread without accepting what it proposed. Nothing reaches Slack.
  """
  def dismiss_triage_thread(%Scope{user: %{id: user_id}}, %Thread{id: thread_id}) do
    Thread
    |> Repo.get!(thread_id)
    |> Ecto.Changeset.change(dismissed_by_id: user_id, dismissed_at: DateTime.utc_now())
    |> Repo.update!()
    |> settle_thread()
  end
end
