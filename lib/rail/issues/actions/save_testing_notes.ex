defmodule Rail.Issues.Actions.SaveTestingNotes do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Replaces the testing notes of a ticket in the testing queue, and returns it as it now reads. Broadcasts
  `{:testing_notes_changed, issue_id}` on `"testing"`, and `{:issue_changed, issue_id}` on `"issues"` when the save
  moved it to In testing. A ticket out of the queue refuses with `:testing_finished`.
  """
  def save_testing_notes(%Scope{} = scope, %Issue{id: id, project_id: project_id}, notes) when is_binary(notes) do
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         {:ok, {was, saved}} <-
           Repo.transaction(fn ->
             locked =
               Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE"))

             cond do
               is_nil(locked) -> Repo.rollback(:not_found)
               not Issue.in_testing_queue?(locked) -> Repo.rollback(:testing_finished)
               true -> {locked, locked |> Issue.testing_notes_changeset(%{testing_notes: notes}) |> Repo.update!()}
             end
           end) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "testing", {:testing_notes_changed, id})

      if was.testing_state != saved.testing_state,
        do: Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})

      {:ok, saved}
    end
  end
end
