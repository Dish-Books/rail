defmodule Rail.Pipeline.Actions.SendFindingsToEngineerTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
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
        name: "Send Findings Project",
        github_repo: "org/send-findings",
        github_installation_id: 47_026,
        linear_workspace: %{
          name: "Send Findings Workspace",
          external_id: "lin_ws_send_findings",
          token: "lin_api_token_send_findings",
          webhook_secret: "whsec_send_findings"
        },
        linear_team_key: "SFE",
        default_branch: "main",
        clone_path: "/tmp/repos/send-findings",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    roles =
      Map.new([:engineer, :review], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sfe_1", "identifier" => "SFE-1", "title" => "Send Findings"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Send Findings"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, engineer_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_send_findings_engineer",
        started_at: DateTime.utc_now()
      })

    {:ok, review_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:review].id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_send_findings_review",
        started_at: DateTime.utc_now()
      })

    {:ok, raised} =
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
        %{key: "naming-nit", title: "Poor variable name", severity: :nit, recommendation: :skip, status: :open}
      ])

    # Nothing is decided until a person decides it, so the fixture rules the way
    # the reviewer advised and each test changes only what it is about.
    findings =
      Enum.map(raised, fn finding ->
        {:ok, decided} = Pipeline.decide_review_finding(finding, finding.recommendation)
        decided
      end)

    %{
      task: task,
      engineer_run: engineer_run,
      review_run: Repo.preload(review_run, [:task, :role]),
      findings: findings
    }
  end

  test "hands the task to the engineer and latches the review run", %{task: task, review_run: run} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_findings_to_engineer(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "the engineer is told only what the human chose to address", %{review_run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ ~s(<finding key="unhandled-nil" severity="major" file="lib/rail/example.ex" line="12">)
      assert prompt =~ "Nil is not handled"
      assert prompt =~ "The clause assumes a map."
      assert prompt =~ "</finding>"
      assert prompt =~ "Continue from where you stopped."
      refute prompt =~ "Poor variable name"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_findings_to_engineer(run)
  end

  # The pending answer is consumed by the spawn, so without this the engineer
  # starts working again with nothing in its conversation saying why.
  test "what was sent is written to the engineer's log", %{engineer_run: engineer_run, review_run: run} do
    assert {:ok, %Run{}} = Pipeline.send_findings_to_engineer(run)

    log = engineer_run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)

    assert log =~ "[human] The reviewer read the change you pushed"
    assert log =~ "Nil is not handled"
    refute log =~ "Poor variable name"
  end

  test "a finding the human put back is sent too", %{review_run: run, findings: findings} do
    nit = Enum.find(findings, &(&1.key == "naming-nit"))
    {:ok, _promoted} = Pipeline.decide_review_finding(nit, :fix)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Poor variable name"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_findings_to_engineer(run)
  end

  test "a finding the reviewer already checked is not sent again", %{
    task: task,
    engineer_run: engineer_run,
    review_run: run
  } do
    {:ok, _synced} =
      Pipeline.sync_review_findings(task, [
        %{key: "unhandled-nil", title: "Nil is not handled", severity: :major, recommendation: :fix, status: :fixed}
      ])

    assert {:error, :nothing_outstanding} = Pipeline.send_findings_to_engineer(run)
    assert %Run{pending_answer: nil} = Repo.reload!(engineer_run)
  end

  test "there is nothing to send when the human dismissed everything", %{review_run: run, findings: findings} do
    for finding <- findings, do: {:ok, _dismissed} = Pipeline.decide_review_finding(finding, :skip)

    assert {:error, :nothing_outstanding} = Pipeline.send_findings_to_engineer(run)
  end

  # Sending while one is undecided would drop it from the round without anyone
  # having said to.
  test "nothing is sent while a finding has no decision", %{task: task, review_run: run} do
    {:ok, _raised} =
      Pipeline.sync_review_findings(task, [
        %{key: "brand-new", title: "Raised on the latest pass", severity: :major, recommendation: :fix, status: :open}
      ])

    assert {:error, :findings_undecided} = Pipeline.send_findings_to_engineer(run)
  end

  test "a project with nobody to send to says so", %{review_run: run} do
    {:ok, engineer_role} = Roles.get_role(project_id: run.task.project_id, stage: :engineer)
    {:ok, _deleted} = Roles.delete_role(system_scope(), engineer_role)

    assert {:error, :no_engineer_role} = Pipeline.send_findings_to_engineer(run)
  end

  test "an engineer that never ran is still entered, with nothing to resume", %{
    task: task,
    engineer_run: engineer_run,
    review_run: run
  } do
    Repo.delete!(engineer_run)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_findings_to_engineer(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a task that has left review has nothing left to send", %{task: task, review_run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :qa})

    assert {:error, {:invalid_stage, :qa}} = Pipeline.send_findings_to_engineer(run)
  end

  test "nothing is sent while something is still running", %{task: task, review_run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_findings_to_engineer(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end
end
