defmodule Rail.Triage.Actions.SendTriageChat do
  @moduledoc false

  import Rail.Triage.Utils.EnqueueTriage

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Thread

  @doc """
  Records the person's line and queues a pass to act on it. A failed pass's error is cleared, so this is the
  retry, and a dismissed thread is back for review, as a new Slack message brings it back.
  """
  def send_triage_chat(%Scope{user: user} = scope, %Thread{id: id}, attrs) do
    thread = Repo.get!(Thread, id)

    with true <- Scope.can_access_project?(scope, thread.project_id) || {:error, :not_found},
         false <- Thread.sending?(thread) && {:error, :already_sending},
         {:ok, line} <- thread |> ChatMessage.person_changeset(user, attrs) |> Repo.insert(),
         {:ok, _thread} <-
           thread |> Ecto.Changeset.change(dismissed_at: nil, dismissed_by_id: nil) |> Repo.update!() |> enqueue_triage() do
      {:ok, line}
    end
  end
end
