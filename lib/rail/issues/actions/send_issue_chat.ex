defmodule Rail.Issues.Actions.SendIssueChat do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.ChatMessage
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.RunIssueChat
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Records the person's line and queues a pass to answer it. A failed pass's error is cleared, so this is the retry.
  """
  def send_issue_chat(%Scope{user: user} = scope, %Issue{id: id, project_id: project_id}, attrs) do
    if Scope.can_access_project?(scope, project_id) do
      fn ->
        # Under the lock the pass saves under, so a task started or a pass begun in another tab is seen here.
        issue =
          from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE")
          |> Repo.one()
          |> Repo.preload(:task)

        with %Issue{} <- issue || {:error, :not_found},
             true <- is_nil(issue.task) || {:error, :task_started},
             false <- Issue.chatting?(issue) && {:error, :agent_running},
             {:ok, line} <- issue |> ChatMessage.person_changeset(user, attrs) |> Repo.insert() do
          issue |> Ecto.Changeset.change(chat_requested_at: DateTime.utc_now(), chat_error: nil) |> Repo.update!()
          {:ok, _job} = Oban.insert(RunIssueChat.new(%{"issue_id" => id}))
          line
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end
      |> Repo.transaction()
      |> tap(fn
        {:ok, %ChatMessage{}} -> Phoenix.PubSub.broadcast(Rail.PubSub, "issue_chats", {:issue_chat_changed, id})
        {:error, _reason} -> :ok
      end)
    else
      {:error, :not_found}
    end
  end
end
