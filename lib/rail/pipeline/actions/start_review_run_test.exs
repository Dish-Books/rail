defmodule Rail.Pipeline.Actions.StartReviewRunTest do
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
        name: "Start Review Project",
        github_repo: "org/start-review",
        github_installation_id: 47_023,
        linear_workspace: %{
          name: "Start Review Workspace",
          external_id: "lin_ws_start_review",
          token: "lin_api_token_start_review",
          webhook_secret: "whsec_start_review"
        },
        linear_team_key: "SRV",
        default_branch: "main",
        clone_path: "/tmp/repos/start-review",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, _created} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :review,
        name: "review role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the review agent."
      })

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_review_1",
              "identifier" => "SRV-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :review)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{task: task, run: run}
  end

  test "briefs the reviewer on the change and the one report file it writes", %{task: task, run: run} do
    reviews_dir = Path.join(task.scratch_path, "reviews")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Review the change described below."
      assert prompt =~ "You are reading it, not changing it"
      assert prompt =~ "git diff origin/main...HEAD"
      assert prompt =~ "The branch #{task.worktree_name}" or prompt =~ task.worktree_name
      assert prompt =~ "cat > #{reviews_dir}/SRV-1.json <<'JSON'"
      assert prompt =~ "Ask everything at once."
      assert prompt =~ "Filter invoices by vendor."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
    assert File.dir?(reviews_dir)
  end

  test "keeps severity and recommendation apart, so a nit can still be worth fixing", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "They are separate axes"
      assert prompt =~ "a nit worth the thirty seconds it costs is `fix`, and a blocker is never `skip`"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  # The human rules on the reasoning and the engineer is handed the remedy, so the
  # two are separate fields and the brief has to say which is which.
  test "tells the reviewer the reasoning and the remedy have different readers", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "`detail` and `suggestion` have different readers"
      assert prompt =~ "the whole of what the engineer is handed"
      assert prompt =~ "whether this change caused the problem or merely stands next to it"
      assert prompt =~ ~s("suggestion": "the change that settles it")
      assert prompt =~ "written as though the finding will be fixed"
      assert prompt =~ "hands the engineer a decision the human has already taken"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "asks the reviewer to confirm what it reports rather than guess", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Report only what you checked."
      assert prompt =~ "open the callers, read the test, run it"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "says the ticket is the whole specification when nothing planned it", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "There is no implementation plan for this ticket"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "reads the change against the plan it was built from", %{task: task, run: run} do
    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content: "## Implementation plan\n\nExtend the invoice filter module.",
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Extend the invoice filter module."
      assert prompt =~ "It is the specification:"
      refute prompt =~ "There is no implementation plan"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "a first pass is not asked to verify anything", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "This change has been reviewed before"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "hands a later pass every finding already on the task, with what the human decided", %{
    task: task,
    run: run
  } do
    {:ok, [to_fix, dismissed]} =
      Pipeline.sync_review_findings(task, [
        %{
          key: "unhandled-nil",
          title: "Nil is not handled",
          detail: "The clause assumes a map.",
          file: "lib/rail/example.ex",
          line: 12,
          severity: :major,
          recommendation: :fix,
          status: :open
        },
        %{
          key: "naming-nit",
          title: "The variable could be named better",
          detail: nil,
          file: nil,
          line: nil,
          severity: :nit,
          recommendation: :fix,
          status: :open
        }
      ])

    {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished})
    {:ok, _to_fix} = Pipeline.decide_review_finding(to_fix, :fix)
    {:ok, _skipped} = Pipeline.decide_review_finding(dismissed, :skip)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "This change has been reviewed before"
      assert prompt =~ "`unhandled-nil` [major, human decided: fix it, status: open] Nil is not handled"
      assert prompt =~ "(lib/rail/example.ex:12)"
      assert prompt =~ "`naming-nit` [nit, human decided: dismissed, leave it, status: open]"
      assert prompt =~ "never argue it again"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end
end
