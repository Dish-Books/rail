defmodule Rail.Issues.Actions.SendIssueToTriage do
  @moduledoc """
  Turns a tested ticket's results into a new ticket in Triage, the tracker asked under the ticket's row lock. So the new
  ticket's own broadcast goes out before the commit, and other writes to the ticket wait on the tracker.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Repo
  alias Rail.Scope

  @refusals [:not_found, :testing_finished, :writing_scenarios, :no_failed_scenarios]

  @doc """
  Opens a ticket in Triage in the tested ticket's project, holding where it was tested, every scenario's result, the
  failed scenarios with their notes and pictures, and a link to it, and returns the new ticket. The tested ticket stays
  in Done as Sent to triage. Refuses with `:no_failed_scenarios` when no scenario failed, `:writing_scenarios` while the
  agent writes, and `:testing_finished` when the ticket is out of the queue.
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
         false <- Issue.writing_scenarios?(locked) && :writing_scenarios,
         true <- Issue.can_send_to_triage?(locked) || :no_failed_scenarios,
         {:ok, created} <-
           Issues.create_issue(scope, locked.project, %{
             title: "Follow-up to #{locked.identifier}: #{locked.title}",
             description: description(locked)
           }) do
      locked |> Ecto.Changeset.change(testing_state: :sent_to_triage) |> Repo.update!()
      created
    else
      {:error, reason} -> Repo.rollback(reason)
      refusal when refusal in @refusals -> Repo.rollback(refusal)
    end
  end

  # A Passed scenario's note and pictures, kept from when it failed, stay out: only failed ones carry details.
  defp description(%Issue{} = issue) do
    %{passed: passed, failed: failed_count, open: open} = Issue.calculate_testing_progress(issue)

    results =
      Enum.map_join(issue.testing_scenarios, "\n", &"- #{TestingScenario.result_label(&1.result)}: #{&1.title}")

    failed =
      for {scenario, number} <- issue.testing_scenarios |> Enum.filter(&(&1.result == :failed)) |> Enum.with_index(1) do
        details = Enum.reject([blank_to_nil(scenario.note) | Enum.map(scenario.images, &picture/1)], &is_nil/1)
        Enum.join(["#{number}. #{scenario.title}" | details], "\n\n   ")
      end

    place =
      Enum.reject(
        [
          issue.testing_environment && Issue.testing_environment_label(issue.testing_environment),
          issue.testing_platform && Issue.testing_platform_label(issue.testing_platform),
          blank_to_nil(issue.testing_device)
        ],
        &is_nil/1
      )

    earlier = Enum.reject([blank_to_nil(issue.testing_notes) | Enum.map(issue.testing_images, &picture/1)], &is_nil/1)

    Enum.join(
      [
        "Found while testing [#{issue.identifier}](#{issue.url})" <>
          if(place == [], do: ".", else: " on #{Enum.join(place, " · ")}."),
        "## Results\n\n#{passed} passed · #{failed_count} failed · #{open} not marked\n\n" <> results,
        "## Failed scenarios\n\n" <> Enum.join(failed, "\n\n")
      ] ++ if(earlier == [], do: [], else: ["## Notes from before scenarios\n\n" <> Enum.join(earlier, "\n\n")]),
      "\n\n"
    )
  end

  defp picture(image), do: "![#{alt(image.name)}](#{image.url})"

  # A bracket in the name would end the picture's markdown early.
  defp alt(name), do: String.replace(name, ["[", "]"], "")

  defp blank_to_nil(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))
  defp blank_to_nil(nil), do: nil
end
