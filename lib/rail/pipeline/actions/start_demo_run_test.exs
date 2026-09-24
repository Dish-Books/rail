defmodule Rail.Pipeline.Actions.StartDemoRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :demo)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_demo_1",
              "identifier" => "SDM-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :demo)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{task: task, run: run}
  end

  test "briefs the demo on the change, the browser and the file it hands over", %{task: task, run: run} do
    demo_dir = Path.join(task.scratch_path, "demo")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Record a walkthrough of the change described below"
      assert prompt =~ "You are showing it, not changing it"
      assert prompt =~ "git diff origin/main...HEAD"
      assert prompt =~ task.worktree_name
      assert prompt =~ "cat > #{demo_dir}/SDM-1.json <<'JSON'"
      assert prompt =~ "Filter invoices by vendor."
      assert prompt =~ "Ask everything at once."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_demo_run(run)
  end

  # A run filmed from its first call to its last is a film of an agent working out
  # how the application behaves, so the brief says where the camera's switch is
  # and that rehearsing costs nothing.
  test "says the rehearsal is off camera and the take is the agent's to start", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Rehearse, then record."
      assert prompt =~ "Nothing is recorded until you call `demo_start`"
      assert prompt =~ "drive the whole walkthrough once"
      assert prompt =~ "Put back anything you changed while rehearsing"
      assert prompt =~ "every save and every submit the take will do"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
  end

  # Investigating with the camera on is a still page in the film for as long as
  # it takes, so the brief says it is the take failing and what to do instead.
  test "says a take is only driving and narrating, and a stumble is a retake", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Once `demo_start` is called you only drive the browser and narrate."
      assert prompt =~ "Reading code, searching the repository"
      assert prompt =~ "call `demo_start` again - it discards the last take"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
  end

  # How a caption lands is Rail's own machinery rather than craft, so the brief
  # is where it is said: a beat said late is a beat over the wrong picture, and a
  # caption cannot point at the frame because Rail draws it outside one.
  test "says what Rail does with a caption", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Rail stamps each caption against the recording's own clock"
      assert prompt =~ "say what is about to happen and then do it"
      assert prompt =~ "renders captions in a bar under the video and never on it"
      assert prompt =~ "nothing you say can point at it"
      assert prompt =~ "Name the acceptance criterion in `criterion`"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
  end

  # Craft belongs to the role's prompt, which the project owns: repeating it on
  # every run is Rail having an opinion it has no business having.
  test "leaves how to make a good walkthrough to the role's own prompt", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "watch your video and open nothing else"
      refute prompt =~ "Shape it as a walkthrough"
      refute prompt =~ "Drive by outcome"
      refute prompt =~ "in the words the person watching would use"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
  end

  # The demo directory is where the write-up and the frames both land, so it
  # exists before the agent does.
  test "the demo directory is made before the run starts", %{task: task, run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
    assert File.dir?(Path.join(task.scratch_path, "demo"))
  end

  # QA found it, a human decided to live with it, and it is still in the
  # application. Walking into it on camera is what the list is handed over to
  # prevent.
  test "hands over the findings a human decided to leave", %{task: task, run: run} do
    # A finding is ruled on at QA, with nothing running, and the task reaches demo
    # afterwards - which is the order that puts a dismissed one in front of the
    # demo at all.
    {:ok, at_qa} = Pipeline.update_task(task, %{stage: :qa})
    {:ok, _settled} = Pipeline.update_run(run, %{status: :finished})

    {:ok, [finding]} =
      Pipeline.sync_qa_findings(task, [
        %{
          key: "totals-off",
          title: "The footer total ignores credits",
          check: "totals",
          screen: "/invoices",
          severity: :minor,
          recommendation: :skip,
          status: :open
        }
      ])

    {:ok, _dismissed} = Pipeline.decide_qa_finding(finding, :skip)
    {:ok, _filming} = Pipeline.update_task(at_qa, %{stage: :demo})

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "QA found these and a human decided to leave them."
      assert prompt =~ "- [minor] The footer total ignores credits (/invoices)"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
  end

  test "a change QA had nothing to say about has no list to avoid", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "a human decided to leave them"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
  end

  test "the approved plan is what says what should now work", %{task: task, run: run} do
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

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
  end

  test "a task that skipped architect is shown on the ticket alone", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "There is no implementation plan for this ticket"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_demo_run(run)
  end
end
