defmodule Rail.Pipeline.Actions.SaveFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Tools

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_svf_1", "identifier" => "SVF-1", "title" => "Save Finding"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Save Finding"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    worktree = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    head = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{
      task: task,
      head: head,
      attrs: %{
        "key" => "send-twice",
        "kind" => "screen",
        "raised_by" => "explorer",
        "title" => "Send stays enabled while a round is on its way",
        "problem" => "A second click sends the same comments twice.",
        "screen" => "Engineer tab, Diff toolbar",
        "steps" => ["Comment on 2 lines", "Click Send", "Click it again"],
        "check" => "send-once",
        "fix" => "Disable Send from the click until the server answers.",
        "why" => "Two runs for one round.",
        "rule" => "A round is sent once, however many times Send is pressed.",
        "severity" => "major",
        "recommendation" => "fix",
        "places" => [%{"screen" => "Engineer tab, Diff toolbar", "steps" => ["Click Send"]}],
        "evidence" => [%{"name" => "count", "kind" => "note", "text" => "2 deliveries"}]
      }
    }
  end

  test "a new finding is raised in the round running against HEAD's commit, and broadcast", %{
    task: %{id: task_id} = task,
    head: head,
    attrs: attrs
  } do
    assert {:ok,
            %Finding{
              key: "send-twice",
              kind: :screen,
              round: 1,
              raised_in: ^head,
              status: :open,
              steps: ["Comment on 2 lines", "Click Send", "Click it again"],
              evidence: [%FindingEvidence{text: "2 deliveries", commit: ^head}],
              notes: [%FindingNote{kind: :raised, round: 1, commit: ^head}]
            }} = Pipeline.save_finding(task, attrs)

    assert_received {:output_saved, ^task_id}
  end

  test "a finding saved after round 1 was closed is raised in round 2", %{task: task, attrs: attrs} do
    {:ok, %{round: 1}} = Pipeline.save_review(task)

    assert {:ok, %Finding{round: 2, notes: [%FindingNote{round: 2}]}} = Pipeline.save_finding(task, attrs)
  end

  test "a new finding without evidence, over a limit or holding markup is refused naming the field", %{
    task: task,
    attrs: attrs
  } do
    assert {:error, changeset} = Pipeline.save_finding(task, Map.delete(attrs, "evidence"))
    assert %{evidence: ["needs at least one highlighted code range, screenshot, file or note"]} = errors_on(changeset)

    assert {:error, changeset} = Pipeline.save_finding(task, %{attrs | "title" => String.duplicate("x", 91)})
    assert %{title: ["should be at most 90 character(s)"]} = errors_on(changeset)

    assert {:error, changeset} = Pipeline.save_finding(task, %{attrs | "problem" => "</invoke> sent twice"})
    assert %{problem: ["holds tool-call markup; write it as plain text"]} = errors_on(changeset)

    assert Pipeline.list_findings(task) == []
  end

  test "evidence naming a file that is not there is refused, naming it", %{task: task, attrs: attrs} do
    missing = [%{"name" => "the log", "kind" => "log", "path" => "evidence/server.log"}]

    assert {:error, changeset} = Pipeline.save_finding(task, %{attrs | "evidence" => missing})
    assert %{evidence: ["evidence/server.log is not a file in " <> _qa_dir]} = errors_on(changeset)
  end

  test "a filed picture carries the commit and the browser it was taken on", %{task: task, head: head, attrs: attrs} do
    source = Path.join([task.scratch_path, "qa", "shot.png"])
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "png bytes")
    {:ok, file} = Tools.file_qa_evidence(task, "shot.png", "Send twice", "send-once", "explorer-1")

    assert {:ok, %Finding{evidence: [%FindingEvidence{path: ^file, commit: ^head, browser: "explorer-1"}]}} =
             Pipeline.save_finding(task, %{
               attrs
               | "evidence" => [%{"name" => "Send twice", "kind" => "screenshot", "path" => file, "browser" => "made up"}]
             })
  end

  test "saving a known key again notes the round and commit, and leaves what it said as raised", %{
    task: task,
    head: head,
    attrs: attrs
  } do
    {:ok, %Finding{id: id}} = Pipeline.save_finding(task, attrs)
    {:ok, %{round: 1}} = Pipeline.save_review(task)

    assert {:ok,
            %Finding{
              id: ^id,
              problem: "A second click sends the same comments twice.",
              fix: "Disable Send from the click until the server answers.",
              screen: "Engineer tab, Diff toolbar",
              status: :fixed,
              notes: [
                %FindingNote{kind: :raised, round: 1},
                %FindingNote{kind: :pass, round: 2, commit: ^head, status: :fixed, text: "Sent once now."}
              ]
            }} =
             Pipeline.save_finding(task, %{
               "key" => "send-twice",
               "status" => "fixed",
               "note" => "Sent once now.",
               "problem" => "Something else entirely.",
               "fix" => "Rewrite it all."
             })
  end

  test "a Fix finding a later round finds still failing is carried into that round, once", %{
    task: task,
    attrs: attrs
  } do
    {:ok, raised} = Pipeline.save_finding(task, attrs)
    {:ok, %{round: 1}} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), raised, :fix)
    {:ok, %{round: 2}} = Pipeline.save_review(task)
    still_failing = %{"key" => "send-twice", "status" => "not_fixed", "note" => "Still sends twice."}

    assert {:ok,
            %Finding{
              carried_round: 3,
              decision: :fix,
              status: :not_fixed,
              notes: [
                %FindingNote{kind: :raised},
                %FindingNote{kind: :ruling},
                %FindingNote{kind: :pass, round: 3, status: :not_fixed},
                %FindingNote{kind: :carried, round: 3}
              ]
            } = carried} = Pipeline.save_finding(task, still_failing)

    assert Finding.outstanding?(carried)
    refute Finding.undecided?(carried)

    assert {:ok, %Finding{notes: notes}} = Pipeline.save_finding(task, still_failing)
    assert [:raised, :ruling, :pass, :carried, :pass] = Enum.map(notes, & &1.kind)
  end

  test "a finding ruled Don't fix is not argued again", %{task: task, attrs: attrs} do
    {:ok, raised} = Pipeline.save_finding(task, attrs)
    {:ok, _dismissed} = Pipeline.decide_finding(system_scope(), raised, :skip)

    assert {:error, changeset} = Pipeline.save_finding(task, %{"key" => "send-twice", "status" => "not_fixed"})
    assert %{key: ["was ruled Don't fix by the human, so leave it be"]} = errors_on(changeset)
  end

  test "a checklist rule's id links the finding, and a calibration rule's suppresses it", %{
    task: task,
    project: project,
    attrs: attrs
  } do
    %{id: checklist_id} = learning(project, %{rule: "Send once", kind: :convention})
    %{id: calibration_id} = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration})

    assert {:ok, %Finding{rule_id: ^checklist_id, suppressed_by_id: nil}} =
             Pipeline.save_finding(task, Map.put(attrs, "checklist_rule", checklist_id))

    assert {:ok, %Finding{rule_id: nil, suppressed_by_id: ^calibration_id}} =
             Pipeline.save_finding(task, Map.put(%{attrs | "key" => "missing-doc"}, "checklist_rule", calibration_id))

    assert {:ok, %Finding{rule_id: nil, suppressed_by_id: nil}} =
             Pipeline.save_finding(task, Map.put(%{attrs | "key" => "made-up-rule"}, "checklist_rule", "lrn_none"))
  end

  test "a task with no worktree on disk raises with no commit", %{task: task, attrs: attrs} do
    {:ok, gone} = Pipeline.update_task(task, %{worktree_path: "/nonexistent/svf"})

    assert {:ok, %Finding{raised_in: nil}} =
             Pipeline.save_finding(gone, Map.new(attrs, fn {k, v} -> {String.to_existing_atom(k), v} end))
  end
end
