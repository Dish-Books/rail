defmodule Rail.Issues.Utils.UpdateTesting do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Applies `change`, given the locked ticket and returning a changeset or `{:error, reason}`, to a ticket in the testing
  queue. Refuses with `:testing_finished` out of the queue and `:writing_scenarios` while the agent writes. Broadcasts
  `{:testing_changed, issue_id}` on `"testing"`, and `{:issue_changed, issue_id}` on `"issues"` when it moved to In testing.
  """
  def update_testing(%Scope{} = scope, %Issue{id: id, project_id: project_id}, change) when is_function(change, 1) do
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         {:ok, {was, saved}} <- Repo.transaction(fn -> apply_change(id, project_id, change) end) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "testing", {:testing_changed, id})

      if was.testing_state != saved.testing_state,
        do: Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})

      {:ok, saved}
    end
  end

  # The agent's pass saves under this lock too, so the writing check holds until it has.
  defp apply_change(id, project_id, change) do
    locked = Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE"))

    with %Issue{} <- locked || {:error, :not_found},
         true <- Issue.in_testing_queue?(locked) || {:error, :testing_finished},
         false <- Issue.writing_scenarios?(locked) && {:error, :writing_scenarios},
         %Ecto.Changeset{} = changeset <- change.(locked),
         {:ok, saved} <- Repo.update(changeset) do
      {locked, saved}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
