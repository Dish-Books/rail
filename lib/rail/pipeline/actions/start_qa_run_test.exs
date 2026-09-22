defmodule Rail.Pipeline.Actions.StartQaRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Qa Project",
        github_repo: "org/start-qa",
        github_installation_id: 47_036,
        linear_workspace: %{
          name: "Start Qa Workspace",
          external_id: "lin_ws_start_qa",
          token: "lin_api_token_start_qa",
          webhook_secret: "whsec_start_qa"
        },
        linear_team_key: "SQA",
        default_branch: "main",
        clone_path: "/tmp/repos/start-qa",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, _created} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :qa,
        name: "qa role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the QA agent."
      })

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :qa)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_qa_1",
              "identifier" => "SQA-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{task: task, run: run}
  end

  test "briefs QA on the change, the report it writes and where evidence goes", %{task: task, run: run} do
    qa_dir = Path.join(task.scratch_path, "qa")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "QA the change described below by driving the running application."
      assert prompt =~ "You are testing it, not changing it"
      assert prompt =~ "git diff origin/main...HEAD"
      assert prompt =~ task.worktree_name
      assert prompt =~ "cat > #{qa_dir}/SQA-1.json <<'JSON'"
      assert prompt =~ "A screenshot comes from `qa_shot`"
      # Reading a picture is what costs, and Rail cannot take one back out of a
      # context once it is in one.
      assert prompt =~ "read one with the Read tool when a check turns on how something looks"
      assert prompt =~ "Anything else you captured goes into #{qa_dir}/evidence"
      assert prompt =~ "Ask everything at once."
      assert prompt =~ "Filter invoices by vendor."

      # The browser and the checklist are Rail's, so the brief is where they are
      # named rather than the project's own prompt.
      assert prompt =~ "`browser_goto`, `browser_do`, `browser_look`, `qa_shot` and `browser_problems`"
      assert prompt =~ "call `qa_plan` with every check this pass will run"
      assert prompt =~ "Call `qa_check` on each one the moment you have run it"
      assert prompt =~ "each under a `group` that says what kind of check it is"
      assert prompt =~ "`qa_shot` takes the row's key as well as a caption"
      assert prompt =~ "`summary` is one or two sentences"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_qa_run(run)
  end

  # The agent writes its screenshots here, so it exists before the agent does.
  test "the evidence directory is made before QA starts", %{task: task, run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
    assert File.dir?(Path.join([task.scratch_path, "qa", "evidence"]))
  end

  test "says the verdict is a judgement rather than a tally", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "`verdict` is `pass`, `concerns` or `fail`"
      assert prompt =~ "your judgement rather than a tally"
      assert prompt =~ "it gates nothing"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "asks for a key that survives the next pass and a check anyone can re-run", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "it must stay the same for the same defect across passes"
      assert prompt =~ "a finding nobody can re-run is a finding nobody can close"
      assert prompt =~ "`caused_by_change` is `false` for something that was already broken"
      assert prompt =~ "never absolute and never climbing out with `..`"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "a first pass has nothing to re-test", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "This change has been QA'd before"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "a later pass is owed a verdict on everything already raised", %{task: task, run: run} do
    {:ok, [outstanding, dismissed]} =
      Pipeline.sync_qa_findings(task, [
        %{
          key: "total-unrounded",
          title: "The total renders as $1234.5",
          check: "A bill's total reads as money",
          screen: "/bills/new",
          severity: :major,
          recommendation: :fix,
          status: :open
        },
        %{
          key: "spacing-nit",
          title: "Buttons sit too close",
          check: "The form looks like the rest of the app",
          severity: :nit,
          recommendation: :skip,
          status: :open,
          caused_by_change: false
        }
      ])

    {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished})
    {:ok, _to_fix} = Pipeline.decide_qa_finding(outstanding, :fix)
    {:ok, _skipped} = Pipeline.decide_qa_finding(dismissed, :skip)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "This change has been QA'd before"
      assert prompt =~ "`total-unrounded` [major, this change, human decided: fix it, status: open]"
      assert prompt =~ "`spacing-nit` [nit, pre-existing, human decided: dismissed, leave it, status: open]"
      assert prompt =~ "(/bills/new)"
      assert prompt =~ "never argue it again"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "a finding nobody has ruled on yet says so", %{task: task, run: run} do
    {:ok, _raised} =
      Pipeline.sync_qa_findings(task, [
        %{key: "one", title: "One", check: "A check", severity: :minor, recommendation: :fix, status: :open}
      ])

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "human decided: not yet decided"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "the plan is the specification when there is one", %{task: task, run: run} do
    {:ok, _plan} =
      %ImplementationPlan{}
      |> ImplementationPlan.changeset(%{
        task_id: task.id,
        content: "Add a vendor filter to the invoice index.",
        captured_at: DateTime.utc_now()
      })
      |> Repo.insert()

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "The approved implementation plan the change was built from."
      assert prompt =~ "Add a vendor filter to the invoice index."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "and the ticket is the whole of it when there is not", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "There is no implementation plan for this ticket"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end
end
