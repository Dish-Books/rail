defmodule Rail.Pipeline.Actions.ListQaFindingsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_list_qa_1", "identifier" => "LSQ-1", "title" => "List Qa"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "List Qa"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "what this change broke comes first, worst first within it", %{task: task} do
    findings =
      for {key, severity, caused} <- [
            {"old-nit", :nit, false},
            {"old-blocker", :blocker, false},
            {"new-minor", :minor, true},
            {"new-blocker", :blocker, true}
          ] do
        %{
          key: key,
          title: key,
          check: "A check",
          severity: severity,
          recommendation: :fix,
          status: :open,
          caused_by_change: caused,
          evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
        }
      end

    for finding <- findings, do: {:ok, _saved} = Pipeline.save_qa_finding(task, finding)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == [
             "new-blocker",
             "new-minor",
             "old-blocker",
             "old-nit"
           ]
  end

  # Where a finding sits is what it is, so ruling on it never loses the reader's place.
  test "a ruling moves nothing", %{task: task} do
    findings =
      for {key, severity} <- [{"a-blocker", :blocker}, {"a-major", :major}, {"a-nit", :nit}] do
        %{
          key: key,
          title: key,
          check: "A check",
          severity: severity,
          recommendation: :fix,
          status: :open,
          evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
        }
      end

    [blocker, major, _nit] =
      for finding <- findings do
        {:ok, saved} = Pipeline.save_qa_finding(task, finding)

        saved
      end

    {:ok, _dismissed} = Pipeline.decide_qa_finding(blocker, :skip)
    {:ok, _decided} = Pipeline.decide_qa_finding(major, :fix)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == ["a-blocker", "a-major", "a-nit"]
  end

  test "a fixed finding stays where its severity puts it", %{task: task} do
    for finding <- [
          %{
            key: "a-blocker",
            title: "A blocker",
            check: "A check",
            severity: :blocker,
            recommendation: :fix,
            status: :fixed,
            evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
          },
          %{
            key: "a-nit",
            title: "A nit",
            check: "A check",
            severity: :nit,
            recommendation: :fix,
            status: :open,
            evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
          }
        ],
        do: {:ok, _saved} = Pipeline.save_qa_finding(task, finding)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == ["a-blocker", "a-nit"]
  end

  test "findings of one severity keep the order they were raised in, however a later pass lists them", %{
    task: task
  } do
    raised =
      for key <- ["a", "b", "c"] do
        %{
          key: key,
          title: key,
          check: "A check",
          severity: :nit,
          recommendation: :fix,
          status: :open,
          evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
        }
      end

    for finding <- raised, do: {:ok, _saved} = Pipeline.save_qa_finding(task, finding)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == ["a", "b", "c"]

    for finding <- Enum.reverse(raised), do: {:ok, _saved} = Pipeline.save_qa_finding(task, finding)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == ["a", "b", "c"]
  end

  test "a tie on when they were raised is broken the same way every time", %{task: task} do
    synced =
      for finding <- [
            %{
              key: "a",
              title: "a",
              check: "A check",
              severity: :nit,
              recommendation: :fix,
              status: :open,
              evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
            },
            %{
              key: "b",
              title: "b",
              check: "A check",
              severity: :nit,
              recommendation: :fix,
              status: :open,
              evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
            }
          ] do
        {:ok, saved} = Pipeline.save_qa_finding(task, finding)
        saved
      end

    # No factory builds findings, so the tie is arranged on the rows sync wrote.
    {2, nil} =
      Repo.update_all(from(f in QaFinding, where: f.task_id == ^task.id),
        set: [inserted_at: ~U[2026-01-01 00:00:00.000000Z]]
      )

    by_id = synced |> Enum.sort_by(& &1.id) |> Enum.map(& &1.key)

    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == by_id
    assert Enum.map(Pipeline.list_qa_findings(task), & &1.key) == by_id
  end

  test "a task QA has not reached has nothing to list", %{task: task} do
    assert Pipeline.list_qa_findings(task) == []
  end
end
