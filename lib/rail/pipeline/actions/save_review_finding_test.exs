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
    {:ok, _dismissed} = Pipeline.decide_review_finding(system_scope(), first, :skip)

    assert {:ok, %ReviewFinding{id: ^id, inserted_at: ^raised_at, decision: :skip, status: :not_fixed, title: "Restated"}} =
             Pipeline.save_review_finding(task, Map.put(%{attrs | "title" => "Restated"}, "status", "not_fixed"))

    assert [%ReviewFinding{id: ^id}] = Pipeline.list_review_findings(task)
  end

  test "a checklist rule's id is the finding's rule, a calibration rule's suppresses it, and an unknown one is dropped",
       %{project: project, task: task, attrs: attrs} do
    %{id: convention_id} = learning(project, %{rule: "Handle nil", kind: :convention})
    %{id: calibration_id} = learning(project, %{rule: "Don't flag nits in docs", kind: :calibration})

    {:ok, other} =
      Rail.Projects.create_project(system_scope(), %{
        name: "Elsewhere #{System.unique_integer([:positive])}",
        github_repo: "x/y",
        github_installation_id: 1,
        default_branch: "main",
        linear_team_key: "ELS",
        clone_path: "/tmp/repos/elsewhere"
      })

    %{id: foreign_id} = learning(other, %{rule: "Theirs", kind: :convention})

    assert {:ok, %ReviewFinding{rule_id: ^convention_id, suppressed_by_id: nil}} =
             Pipeline.save_review_finding(task, Map.put(attrs, "rule", convention_id))

    assert {:ok, %ReviewFinding{rule_id: nil, suppressed_by_id: ^calibration_id} = suppressed} =
             Pipeline.save_review_finding(task, Map.put(%{attrs | "key" => "doc-nit"}, "rule", calibration_id))

    assert ReviewFinding.state(suppressed) == :suppressed

    for {key, rule} <- [{"foreign", foreign_id}, {"unknown", "lrn_unknown"}] do
      assert {:ok, %ReviewFinding{rule_id: nil, suppressed_by_id: nil}} =
               Pipeline.save_review_finding(task, Map.put(%{attrs | "key" => key}, "rule", rule))
    end
  end

  # A rule is linked only by looking up the id the reviewer gave, never set by name.
  test "a rule a later save leaves out is no longer linked", %{project: project, task: task, attrs: attrs} do
    %{id: convention_id} = learning(project, %{rule: "Handle nil", kind: :convention})
    {:ok, _linked} = Pipeline.save_review_finding(task, Map.put(attrs, "rule", convention_id))

    assert {:ok, %ReviewFinding{rule_id: nil}} =
             Pipeline.save_review_finding(task, Map.put(attrs, "rule_id", convention_id))
  end
end
