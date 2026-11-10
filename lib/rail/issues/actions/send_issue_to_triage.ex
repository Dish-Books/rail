defmodule Rail.Issues.Actions.SendIssueToTriage do
  @moduledoc """
  Turns a tested ticket's notes into a new ticket in Triage. The tested ticket leaves the queue under its row lock
  before the tracker is asked, so a second send finds it gone, and returns to the queue if the tracker refuses.
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
         {:ok, {held, tested}} <- claim(id, project_id) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})

      attrs = %{
        title: "Follow-up to #{tested.identifier}: #{tested.title}",
        description: "#{String.trim(tested.testing_notes)}\n\nFound while testing [#{tested.identifier}](#{tested.url})."
      }

      case Issues.create_issue(scope, tested.project, attrs) do
        {:ok, created} ->
          {:ok, created}

        {:error, reason} ->
          release(tested, held)
          {:error, reason}
      end
    end
  end

  defp claim(id, project_id) do
    Repo.transaction(fn ->
      locked =
        Repo.one(
          from(i in Issue,
            where: i.id == ^id and i.project_id == ^project_id,
            lock: "FOR UPDATE",
            preload: :project
          )
        )

      cond do
        is_nil(locked) ->
          Repo.rollback(:not_found)

        not Issue.in_testing_queue?(locked) ->
          Repo.rollback(:testing_finished)

        String.trim(locked.testing_notes || "") == "" ->
          Repo.rollback(:no_notes)

        true ->
          {locked.testing_state, locked |> Ecto.Changeset.change(testing_state: :sent_to_triage) |> Repo.update!()}
      end
    end)
  end

  # Only while it still reads Sent to triage in Done: a move out of Done since the claim has already settled it.
  defp release(%Issue{id: id, project_id: project_id}, held) do
    Repo.update_all(
      from(i in Issue,
        where: i.id == ^id and i.project_id == ^project_id,
        where: i.state == :done and i.testing_state == :sent_to_triage
      ),
      set: [testing_state: held]
    )

    Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
  end
end
