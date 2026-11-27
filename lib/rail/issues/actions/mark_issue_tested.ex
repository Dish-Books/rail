defmodule Rail.Issues.Actions.MarkIssueTested do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Marks a ticket in the testing queue Tested, leaving it in Done with its scenarios, and broadcasts
  `{:issue_changed, issue_id}` on `"issues"`. A ticket with no scenarios needs `no_scenarios_reason` in `attrs`, else
  the changeset's error comes back. Refuses with `:testing_finished` out of the queue, `:writing_scenarios` while the
  agent writes, and `:scenarios_open` while a scenario is Failed or unmarked.
  """
  def mark_issue_tested(%Scope{} = scope, %Issue{id: id, project_id: project_id}, attrs) when is_map(attrs) do
    # Under the lock the other testing writes take, so a second click or tab finds the ticket already Tested.
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         {:ok, tested} <- Repo.transaction(fn -> mark(id, project_id, attrs) end) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
      {:ok, tested}
    end
  end

  defp mark(id, project_id, attrs) do
    locked = Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE"))

    with %Issue{} <- locked || {:error, :not_found},
         true <- Issue.in_testing_queue?(locked) || {:error, :testing_finished},
         false <- Issue.writing_scenarios?(locked) && {:error, :writing_scenarios},
         true <- Issue.can_mark_tested?(locked) || {:error, :scenarios_open},
         {:ok, tested} <- locked |> Issue.tested_changeset(attrs) |> Repo.update() do
      tested
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
