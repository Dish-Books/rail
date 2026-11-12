defmodule Rail.Issues.Actions.MarkIssueTested do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Marks a ticket in the testing queue Tested, leaving it in Done with its notes, and broadcasts
  `{:issue_changed, issue_id}` on `"issues"`. A ticket out of the queue refuses with `:testing_finished`.
  """
  def mark_issue_tested(%Scope{} = scope, %Issue{id: id, project_id: project_id}) do
    # One conditional update, so a second click or tab finds nothing left to claim.
    queued =
      from(i in Issue,
        where: i.id == ^id and i.project_id == ^project_id and i.state == :done,
        where: i.testing_state in ^[:waiting, :testing],
        select: i
      )

    if Scope.can_access_project?(scope, project_id) do
      case Repo.update_all(queued, set: [testing_state: :tested, updated_at: DateTime.utc_now()]) do
        {1, [tested]} ->
          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
          {:ok, tested}

        {0, []} ->
          {:error, :testing_finished}
      end
    else
      {:error, :not_found}
    end
  end
end
