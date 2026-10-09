defmodule Rail.Pipeline.Actions.ListFindingsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_lsf_1", "identifier" => "LSF-1", "title" => "List Findings"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "List Findings"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{
      task: task,
      code: %{
        kind: :code,
        raised_by: :code_reviewer,
        problem: "It breaks.",
        file: "lib/a.ex",
        line: 3,
        fix: "Mend it.",
        why: "It breaks.",
        rule: "Nothing breaks.",
        recommendation: :fix,
        places: [%{file: "lib/a.ex", line: 3}],
        evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
      },
      screen: %{
        kind: :screen,
        raised_by: :explorer,
        problem: "It looks wrong.",
        screen: "Overview",
        steps: ["Open it"],
        fix: "Mend it.",
        why: "It looks wrong.",
        rule: "Nothing looks wrong.",
        recommendation: :fix,
        places: [%{screen: "Overview"}],
        evidence: [%{name: "count", kind: :note, text: "3"}]
      }
    }
  end

  test "code and screen findings list newest round first, a carried one after those raised in it, then worst first",
       %{task: task, code: code, screen: screen} do
    {:ok, _nit} = Pipeline.save_finding(task, Map.merge(code, %{key: "round-1-nit", title: "A nit", severity: :nit}))

    {:ok, carried} =
      Pipeline.save_finding(task, Map.merge(screen, %{key: "round-1-major", title: "A major", severity: :major}))

    {:ok, %{round: 1}} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), carried, :fix)

    {:ok, _minor} =
      Pipeline.save_finding(task, Map.merge(screen, %{key: "round-2-minor", title: "A minor", severity: :minor}))

    {:ok, _blocker} =
      Pipeline.save_finding(task, Map.merge(code, %{key: "round-2-blocker", title: "A blocker", severity: :blocker}))

    {:ok, %Finding{carried_round: 2}} =
      Pipeline.save_finding(task, %{key: "round-1-major", status: "not_fixed", note: "Still wrong."})

    assert ["round-2-blocker", "round-2-minor", "round-1-major", "round-1-nit"] =
             task |> Pipeline.list_findings() |> Enum.map(& &1.key)
  end

  test "findings of one round and severity list oldest first, with the id breaking a tie", %{task: task, code: code} do
    {:ok, %Finding{id: first}} =
      Pipeline.save_finding(task, Map.merge(code, %{key: "first", title: "First", severity: :major}))

    {:ok, %Finding{id: second}} =
      Pipeline.save_finding(task, Map.merge(code, %{key: "second", title: "Second", severity: :major}))

    assert [%Finding{id: ^first}, %Finding{id: ^second}] = Pipeline.list_findings(task)
  end
end
