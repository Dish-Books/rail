defmodule Rail.Issues.Actions.RequestTestScenarios do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.WriteTestScenarios
  alias Rail.Repo

  @doc """
  Stamps `issue` as waiting on its scenarios and queues the pass that reads `merge_sha`, in the caller's transaction
  when there is one. A ticket already Tested or Sent to triage is returned as it is.
  """
  def request_test_scenarios(%Issue{id: id, project_id: project_id}, merge_sha) when is_binary(merge_sha) do
    Repo.transaction(fn ->
      # Under the lock Mark tested and Send to triage take, so neither can finish the ticket between check and stamp.
      locked = Repo.one!(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE"))

      if locked.testing_state in [:tested, :sent_to_triage] do
        locked
      else
        requested = locked |> Issue.scenarios_requested_changeset(DateTime.utc_now()) |> Repo.update!()
        {:ok, _job} = %{issue_id: id, merge_sha: merge_sha} |> WriteTestScenarios.new() |> Oban.insert()
        requested
      end
    end)
  end
end
