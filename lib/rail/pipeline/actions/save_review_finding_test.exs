defmodule Rail.Pipeline.Actions.SaveReviewFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_srf_1", "identifier" => "SRF-1", "title" => "Save Review Finding"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Save Review Finding"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{
      task: task,
      attrs: %{
        "key" => "comment-saved-during-send",
        "title" => "A comment saved during a send is dropped",
        "file" => "lib/rail/pipeline/diff_comments.ex",
        "line" => 212,
        "severity" => "major",
        "recommendation" => "fix"
      }
    }
  end

  test "a finding is saved as a row and every open page hears", %{task: %{id: task_id} = task, attrs: attrs} do
    assert {:ok, %ReviewFinding{key: "comment-saved-during-send", line: 212, severity: :major, status: :open}} =
             Pipeline.save_review_finding(task, attrs)

    assert [%ReviewFinding{key: "comment-saved-during-send"}] = Pipeline.list_review_findings(task)
    assert_received {:output_saved, ^task_id}
  end

  test "an unknown severity and a line range are refused together, and nothing is saved", %{task: task, attrs: attrs} do
    assert {:error, changeset} = Pipeline.save_review_finding(task, %{attrs | "severity" => "high", "line" => "88-94"})
    assert %{severity: ["is invalid"], line: ["is invalid"]} = errors_on(changeset)

    assert Pipeline.list_review_findings(task) == []
    refute_received {:output_saved, _task_id}
  end

  test "a finding cannot name another task", %{project: project, task: %{id: task_id} = task, attrs: attrs} do
    assert {:ok, %ReviewFinding{task_id: ^task_id}} =
             Pipeline.save_review_finding(task, Map.put(attrs, "task_id", project.id))
  end

  # The decision is the human's and the first-raised time is history, so a save
  # on the same key restates everything else and leaves those alone.
  test "saving a key again updates it in place and keeps the human's decision", %{task: task, attrs: attrs} do
    {:ok, %ReviewFinding{id: id, inserted_at: raised_at} = first} = Pipeline.save_review_finding(task, attrs)
    {:ok, _dismissed} = Pipeline.decide_review_finding(first, :skip)

    assert {:ok, %ReviewFinding{id: ^id, inserted_at: ^raised_at, decision: :skip, status: :not_fixed, title: "Restated"}} =
             Pipeline.save_review_finding(task, Map.put(%{attrs | "title" => "Restated"}, "status", "not_fixed"))

    assert [%ReviewFinding{id: ^id}] = Pipeline.list_review_findings(task)
  end
end
