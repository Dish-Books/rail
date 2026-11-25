defmodule RailWeb.Mcp.Tools.DecideFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Users

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    key = "mdf#{System.unique_integer([:positive])}"

    [user, teammate] =
      for name <- ["mdf", "mdf_mate"] do
        {:ok, user} =
          Users.register_oauth_user(%{
            github_id: "#{name}_#{key}",
            login: "#{name}_#{key}",
            name: name,
            email: "#{name}_#{key}@example.com"
          })

        {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
        user
      end

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Ruled", owner_user_id: user.id})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    attrs = %{
      key: "send-twice",
      kind: :code,
      raised_by: :code_reviewer,
      title: "Send posts twice",
      problem: "A second click posts the comment again.",
      file: "lib/send.ex",
      line: 12,
      fix: "Disable Send until the server answers.",
      why: "Two posts confuse the thread.",
      rule: "A second click does nothing harmful.",
      severity: :major,
      recommendation: :fix,
      places: [%{file: "lib/send.ex", line: 12}],
      evidence: [%{name: "The handler", kind: :code, file: "lib/send.ex", line: 12}]
    }

    {:ok, finding} = Pipeline.save_finding(task, attrs)
    {:ok, %{round: 1}} = Pipeline.save_review(task)

    %{
      project: project,
      user: user,
      teammate: teammate,
      issue: issue,
      task: task,
      attrs: attrs,
      finding: finding,
      scope: Rail.Scope.for_user(user)
    }
  end

  test "Don't fix from Claude is saved as the caller, said to an open task page, and answered with the finding", %{
    issue: %{identifier: identifier},
    task: %{id: task_id},
    user: %{id: user_id, login: login},
    finding: %{id: finding_id},
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    {:ok, %{"findings" => [%{"version" => version}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    assert {:ok,
            %{
              "finding" => %{
                "key" => "send-twice",
                "version" => "1@" <> _updated_at,
                "recommendation" => %{"decision" => "fix"},
                "ruling" => %{"decision" => "dont_fix", "by" => ^login},
                "history" => [%{"kind" => "raised"}, %{"kind" => "ruling", "decision" => "dont_fix", "by" => ^login}]
              }
            }} =
             call_mcp_tool(scope, "decide_finding", %{
               "identifier" => identifier,
               "key" => "send-twice",
               "decision" => "dont_fix",
               "version" => version
             })

    assert_received {:output_saved, ^task_id}
    assert_receive {:pipeline_changed, ^task_id}

    assert %Finding{decision: :skip, decided_by_id: ^user_id, notes: [_raised, %FindingNote{by_id: ^user_id}]} =
             Repo.get!(Finding, finding_id)
  end

  test "New issue from Claude is saved and waits for Send: nothing is filed, no fix round starts, the review stays open",
       %{issue: %{identifier: identifier}, task: %{id: task_id} = task, user: %{id: user_id}, scope: scope} do
    reject(Issues, :create_issue, 3)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

    {:ok, %{"findings" => [%{"version" => version}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    assert {:ok, %{"finding" => %{"ruling" => %{"decision" => "new_issue"}, "filed_as" => nil, "status" => "open"}}} =
             call_mcp_tool(scope, "decide_finding", %{
               "identifier" => identifier,
               "key" => "send-twice",
               "decision" => "new_issue",
               "version" => version
             })

    assert_received {:output_saved, ^task_id}

    assert [%Finding{decision: :new_issue, decided_by_id: ^user_id, issue_id: nil}] =
             Pipeline.list_findings(task)

    assert [] = Pipeline.list_runs(task_id: task_id)
    assert [%{round: 1, finished_at: nil}] = Pipeline.read_review(Repo.preload(task, :issue))
    assert {:ok, %{stage: :review}} = Pipeline.get_task(task_id)
  end

  test "the same ruling sent twice answers both times and is noted once", %{
    issue: %{identifier: identifier},
    finding: %{id: finding_id},
    scope: scope
  } do
    {:ok, %{"findings" => [%{"version" => version}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    call = %{"identifier" => identifier, "key" => "send-twice", "decision" => "dont_fix", "version" => version}

    assert {:ok, %{"finding" => %{"ruling" => %{"decision" => "dont_fix"}} = first}} =
             call_mcp_tool(scope, "decide_finding", call)

    assert {:ok, %{"finding" => ^first}} = call_mcp_tool(scope, "decide_finding", call)
    assert %Finding{notes: [_raised, %FindingNote{kind: :ruling}]} = Repo.get!(Finding, finding_id)
  end

  test "a teammate's ruling in Rail since the read is not overwritten", %{
    issue: %{identifier: identifier},
    teammate: %{id: teammate_id} = teammate,
    finding: %{id: finding_id} = finding,
    scope: scope
  } do
    {:ok, %{"findings" => [%{"version" => version}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    {:ok, _fixed} = Pipeline.decide_finding(user_scope(user: teammate), finding, :fix)

    assert {:error,
            "That finding changed since you read it, so nothing was saved. Read it again with list_findings, then rule."} =
             call_mcp_tool(scope, "decide_finding", %{
               "identifier" => identifier,
               "key" => "send-twice",
               "decision" => "dont_fix",
               "version" => version
             })

    assert %Finding{decision: :fix, decided_by_id: ^teammate_id, notes: [_raised, %FindingNote{decision: :fix}]} =
             Repo.get!(Finding, finding_id)
  end

  test "a ruling read before a new round is refused, and goes through once read again", %{
    issue: %{identifier: identifier},
    task: task,
    finding: %{id: finding_id},
    scope: scope
  } do
    {:ok, %{"findings" => [%{"version" => "1@" <> _at = stale}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    {:ok, %{round: 2}} = Pipeline.save_review(task)
    call = %{"identifier" => identifier, "key" => "send-twice", "decision" => "dont_fix", "version" => stale}

    assert {:error,
            "A new review round opened since you read that finding, so nothing was saved. " <>
              "Read it again with list_findings, then rule."} = call_mcp_tool(scope, "decide_finding", call)

    assert %Finding{decision: nil, notes: [_raised]} = Repo.get!(Finding, finding_id)

    {:ok, %{"findings" => [%{"version" => "2@" <> _at = fresh}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    assert {:ok, %{"finding" => %{"ruling" => %{"decision" => "dont_fix"}}}} =
             call_mcp_tool(scope, "decide_finding", %{call | "version" => fresh})

    assert %Finding{decision: :skip, notes: [_raised, %FindingNote{kind: :ruling, round: 2}]} =
             Repo.get!(Finding, finding_id)
  end

  test "a round that opens as the ruling is read back says the ruling is saved", %{
    issue: %{identifier: identifier},
    finding: %{id: finding_id},
    scope: scope
  } do
    {:ok, %{"findings" => [%{"version" => version}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    stub(Pipeline, :list_findings, fn task -> call_original(Pipeline, :list_findings, [task]) end)
    expect(Pipeline, :list_findings, fn task -> call_original(Pipeline, :list_findings, [task]) end)

    expect(Pipeline, :list_findings, fn task ->
      {:ok, %{round: 2}} = Pipeline.save_review(task)
      call_original(Pipeline, :list_findings, [task])
    end)

    assert {:error,
            "Your ruling is saved, but a new review round opened as Rail read it back. Read it again with list_findings."} =
             call_mcp_tool(scope, "decide_finding", %{
               "identifier" => identifier,
               "key" => "send-twice",
               "decision" => "dont_fix",
               "version" => version
             })

    assert %Finding{decision: :skip, notes: [_raised, %FindingNote{kind: :ruling, round: 1}]} =
             Repo.get!(Finding, finding_id)
  end

  test "a ticket gone as the ruling is read back still says the ruling is saved", %{
    issue: %{identifier: identifier},
    finding: %{id: finding_id},
    scope: scope
  } do
    {:ok, %{"findings" => [%{"version" => version}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    expect(Issues, :find_issue, fn scope, identifier, opts ->
      call_original(Issues, :find_issue, [scope, identifier, opts])
    end)

    expect(Issues, :find_issue, fn _scope, _identifier, _opts -> {:error, :not_found} end)

    assert {:error, "Your ruling is saved, but Rail could not read it back: No ticket " <> _rest} =
             call_mcp_tool(scope, "decide_finding", %{
               "identifier" => identifier,
               "key" => "send-twice",
               "decision" => "fix",
               "version" => version
             })

    assert %Finding{decision: :fix} = Repo.get!(Finding, finding_id)
  end

  test "an unreadable version, an unknown key or a run at work is refused, and the finding is left alone", %{
    project: project,
    issue: %{identifier: identifier},
    task: task,
    finding: %{id: finding_id},
    scope: scope
  } do
    {:ok, %{"findings" => [%{"version" => version}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    call = %{"identifier" => identifier, "key" => "send-twice", "decision" => "dont_fix", "version" => version}

    for unreadable <- ["nonsense", "x@2026-11-24T10:00:00Z", "1@yesterday", "-1@2026-11-24T10:00:00Z"] do
      assert {:error, "version is not one list_findings gave."} =
               call_mcp_tool(scope, "decide_finding", %{call | "version" => unreadable})
    end

    said = "#{identifier} has no finding gone-key. list_findings gives each finding's key."
    assert {:error, ^said} = call_mcp_tool(scope, "decide_finding", %{call | "key" => "gone-key"})

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, _run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    assert {:error, "A run is working on this task. Rule once it stops."} = call_mcp_tool(scope, "decide_finding", call)
    assert %Finding{decision: nil, notes: [_raised]} = Repo.get!(Finding, finding_id)
  end

  test "a finished review and a task past Review are refused, and the ruling is left alone", %{
    project: project,
    issue: %{identifier: identifier},
    task: task,
    finding: %{id: finding_id} = finding,
    scope: scope
  } do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    {:ok, _skipped} = Pipeline.decide_finding(system_scope(), finding, :skip)
    {:ok, %Run{status: :finished}} = Pipeline.start_fix_round(system_scope(), run)

    {:ok, %{"findings" => [%{"version" => version}]}} =
      call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})

    call = %{"identifier" => identifier, "key" => "send-twice", "decision" => "fix", "version" => version}

    assert {:error, "This task is at Finalize, not Review, so its findings can't be ruled on."} =
             call_mcp_tool(scope, "decide_finding", call)

    # A review finished before Finalize shipped left its task at Review.
    {:ok, _legacy} = Pipeline.update_task(Repo.reload!(task), %{stage: :review})

    assert {:error, "The review is finished, so its rulings are settled."} =
             call_mcp_tool(scope, "decide_finding", call)

    assert %Finding{decision: :skip, notes: [_raised, _ruled]} = Repo.get!(Finding, finding_id)
  end

  test "a filed, fixed or suppressed finding is refused what the task page would refuse", %{
    project: project,
    issue: %{identifier: identifier},
    task: task,
    attrs: attrs,
    finding: finding,
    scope: scope
  } do
    {:ok, new_issue} = Pipeline.decide_finding(system_scope(), finding, :new_issue)
    {:ok, [_filed]} = Pipeline.file_finding_issues(system_scope(), Repo.preload(task, [:issue, :project]), [new_issue])

    {:ok, _raised} = Pipeline.save_finding(task, %{attrs | key: "stale-cache", recommendation: :skip})
    # A later pass found it fixed by the work around it.
    {:ok, %Finding{status: :fixed}} = Pipeline.save_finding(task, %{key: "stale-cache", status: "fixed"})

    %{id: rule_id} = learning(project, %{rule: "Don't flag a nil clause", kind: :calibration})

    {:ok, %Finding{suppressed_by_id: ^rule_id}} =
      Pipeline.save_finding(task, Map.merge(attrs, %{key: "nil-clause", checklist_rule: rule_id}))

    {:ok, %{"findings" => findings}} = call_mcp_tool(scope, "list_findings", %{"identifier" => identifier})
    versions = Map.new(findings, &{&1["key"], &1["version"]})
    before = Pipeline.list_findings(task)

    for {key, decision, said} <- [
          {"send-twice", "fix", "That finding is filed as a new issue, so its ruling can no longer change."},
          {"stale-cache", "fix", "That finding is fixed, so its ruling can no longer change."},
          {"nil-clause", "dont_fix", "A rule already leaves that finding alone, so the only ruling it takes is fix."},
          {"nil-clause", "new_issue", "A rule already leaves that finding alone, so the only ruling it takes is fix."}
        ] do
      call = %{"identifier" => identifier, "key" => key, "decision" => decision, "version" => versions[key]}
      assert {:error, ^said} = call_mcp_tool(scope, "decide_finding", call)
    end

    assert Pipeline.list_findings(task) == before
  end
end
