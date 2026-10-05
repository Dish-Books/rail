defmodule Rail.Pipeline.Actions.SaveQaFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.QaFinding

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sqf_1", "identifier" => "SQF-1", "title" => "Save Qa Finding"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Save Qa Finding"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    evidence = Path.join([task.scratch_path, "qa", "evidence"])
    File.mkdir_p!(evidence)
    File.write!(Path.join(evidence, "focus~lost-after-send.jpg"), "jpeg bytes")
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{
      task: task,
      attrs: %{
        "key" => "answer-field-focus",
        "title" => "The answer field loses focus after Send",
        "check" => "focus",
        "severity" => "major",
        "recommendation" => "fix",
        "evidence" => [%{"name" => "focus lost", "kind" => "screenshot", "path" => "evidence/focus~lost-after-send.jpg"}]
      }
    }
  end

  test "a finding citing a filed picture is saved and broadcast", %{task: %{id: task_id} = task, attrs: attrs} do
    assert {:ok,
            %QaFinding{key: "answer-field-focus", evidence: [%QaEvidence{path: "evidence/focus~lost-after-send.jpg"}]}} =
             Pipeline.save_qa_finding(task, attrs)

    assert_received {:output_saved, ^task_id}
  end

  test "a finding with no evidence is refused", %{task: task, attrs: attrs} do
    assert {:error, changeset} = Pipeline.save_qa_finding(task, Map.delete(attrs, "evidence"))
    assert %{evidence: ["needs at least one screenshot, file or note showing the defect"]} = errors_on(changeset)
    assert Pipeline.list_qa_findings(task) == []
  end

  test "evidence outside the QA folder is refused", %{task: task, attrs: attrs} do
    outside = [%{"name" => "secrets", "kind" => "log", "path" => "../../etc/passwd"}]

    assert {:error, changeset} = Pipeline.save_qa_finding(task, %{attrs | "evidence" => outside})
    refute changeset.valid?
    assert Pipeline.list_qa_findings(task) == []
  end

  test "evidence naming a file that is not there is refused, naming it", %{task: task, attrs: attrs} do
    missing = [%{"name" => "the log", "kind" => "log", "path" => "evidence/server.log"}]

    assert {:error, changeset} = Pipeline.save_qa_finding(task, %{attrs | "evidence" => missing})
    assert %{evidence: ["evidence/server.log is not a file in " <> _qa_dir]} = errors_on(changeset)
  end

  test "saving a key again keeps the human's decision", %{task: task, attrs: attrs} do
    {:ok, %QaFinding{id: id} = first} = Pipeline.save_qa_finding(task, attrs)
    {:ok, _to_fix} = Pipeline.decide_qa_finding(first, :fix)

    assert {:ok, %QaFinding{id: ^id, decision: :fix, status: :fixed}} =
             Pipeline.save_qa_finding(task, Map.put(attrs, "status", "fixed"))
  end
end
