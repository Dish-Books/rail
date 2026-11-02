defmodule Rail.Pipeline.Actions.FileFindingIssuesTest do
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
            "issue" => %{"id" => "lin_ffi_1", "identifier" => "FFI-1", "title" => "File Finding Issues"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "File Finding Issues"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    task = Repo.preload(task, [:issue, :project])
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    attrs = %{
      kind: :screen,
      raised_by: :explorer,
      problem: "It overflows.",
      screen: "Task page, header",
      steps: ["Open a task"],
      fix: "Truncate it.",
      why: "It predates this branch.",
      rule: "Nothing overflows at 1280px.",
      severity: :minor,
      recommendation: :skip,
      places: [%{screen: "Task page, header"}],
      evidence: [%{name: "note", kind: :note, text: "Seen at 1280px."}]
    }

    {:ok, first} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "branch-overflow", title: "The branch overflows"}))
    {:ok, second} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "resort", title: "The list re-sorts"}))
    {:ok, %{round: 1}} = Pipeline.save_review(task)
    {:ok, first} = Pipeline.decide_finding(system_scope(), first, :new_issue)
    {:ok, second} = Pipeline.decide_finding(system_scope(), second, :new_issue)

    %{
      task: task,
      first: first,
      second: second,
      filed: fn identifier ->
        fn conn ->
          assert %{"variables" => %{"input" => %{"title" => title, "stateId" => "st_triage"}}} =
                   conn |> Req.Test.raw_body() |> Jason.decode!()

          Req.Test.json(conn, %{
            "data" => %{
              "issueCreate" => %{
                "success" => true,
                "issue" => %{"id" => "lin_#{identifier}", "identifier" => identifier, "title" => title}
              }
            }
          })
        end
      end
    }
  end

  test "files one issue per finding, oldest first, and a second filing of the same findings files none", %{
    task: %{id: task_id} = task,
    first: first,
    second: second,
    filed: filed
  } do
    Req.Test.expect(Rail.Linear, filed.("FFI-2"))
    Req.Test.expect(Rail.Linear, filed.("FFI-3"))
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

    assert {:ok,
            [
              %Finding{key: "branch-overflow", issue: %{identifier: "FFI-2", title: "The branch overflows"}},
              %Finding{key: "resort", issue: %{identifier: "FFI-3"}}
            ]} = Pipeline.file_finding_issues(system_scope(), task, [second, first])

    assert_received {:output_saved, ^task_id}

    # Each tracker call above was expected once, so another would fail the test.
    assert {:ok, []} = Pipeline.file_finding_issues(system_scope(), task, [first, second])
    refute_received {:output_saved, ^task_id}
  end

  test "a refusal stops the filing there, and the issue already filed stays", %{
    task: %{id: task_id} = task,
    first: %{id: first_id} = first,
    second: %{id: second_id} = second,
    filed: filed
  } do
    Req.Test.expect(Rail.Linear, filed.("FFI-2"))
    Req.Test.expect(Rail.Linear, &Plug.Conn.send_resp(&1, 500, "down"))
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

    assert {:error, {:issue_not_filed, "The list re-sorts"}, [%Finding{id: ^first_id}]} =
             Pipeline.file_finding_issues(system_scope(), task, [first, second])

    assert_received {:output_saved, ^task_id}
    assert %Finding{issue_id: "iss" <> _id} = Repo.get!(Finding, first_id)
    assert %Finding{decision: :new_issue, issue_id: nil} = Repo.get!(Finding, second_id)
  end

  test "a refusal with nothing filed says nothing to the page", %{task: %{id: task_id} = task, second: second} do
    Req.Test.expect(Rail.Linear, &Plug.Conn.send_resp(&1, 500, "down"))
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

    assert {:error, {:issue_not_filed, "The list re-sorts"}, []} =
             Pipeline.file_finding_issues(system_scope(), task, [second])

    refute_received {:output_saved, ^task_id}
  end
end
