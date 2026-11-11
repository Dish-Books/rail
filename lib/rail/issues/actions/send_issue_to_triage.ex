defmodule Rail.Issues.Actions.SendIssueToTriage do
  @moduledoc """
  Turns a tested ticket's notes into a new ticket in Triage, the tracker asked under the ticket's row lock. So the new
  ticket's own broadcast goes out before the commit, and other writes to the ticket wait on the tracker.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Opens a ticket in Triage in the tested ticket's project, holding its notes and a link to it, and returns the new
  ticket. The tested ticket stays in Done as Sent to triage. Refuses with `:no_notes` when the notes are blank, and
  with `:testing_finished` when the ticket is out of the queue.
  """
  def send_issue_to_triage(%Scope{} = scope, %Issue{id: id, project_id: project_id}) do
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         {:ok, created} <- Repo.transaction(fn -> file(scope, id, project_id) end) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
      {:ok, created}
    end
  end

  # The tracker call sits inside the lock: a claim committed before it would strand the ticket on a crash.
  defp file(scope, id, project_id) do
    locked =
      Repo.one(
        from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE", preload: :project)
      )

    with %Issue{} <- locked || :not_found,
         true <- Issue.in_testing_queue?(locked) || :testing_finished,
         true <- String.trim(locked.testing_notes || "") != "" || :no_notes,
         {:ok, created} <-
           Issues.create_issue(scope, locked.project, %{
             title: "Follow-up to #{locked.identifier}: #{locked.title}",
             description:
               "#{String.trim(locked.testing_notes)}\n\nFound while testing [#{locked.identifier}](#{locked.url})."
           }) do
      locked |> Ecto.Changeset.change(testing_state: :sent_to_triage) |> Repo.update!()
      created
    else
      {:error, reason} -> Repo.rollback(reason)
      refusal when refusal in [:not_found, :testing_finished, :no_notes] -> Repo.rollback(refusal)
    end
  end
end
