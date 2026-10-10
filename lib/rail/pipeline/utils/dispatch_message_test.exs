defmodule Rail.Pipeline.Utils.DispatchMessageTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.DispatchMessage

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_dispatch_message_1",
              "identifier" => "DSP-1",
              "title" => "Dispatch Message Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Dispatch Message Issue"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

    {:ok, %Run{id: run_id} = run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_dispatch_message",
        pending_chat: "Please also add a test",
        started_at: DateTime.utc_now()
      })

    # Says which task's turn was readied, so a test can tell a turn that commits from one that does not, and
    # finds its branch behind, which the turn's prompt opens with.
    test_pid = self()

    stub(Rail.Pipeline.Utils.PrepareTurn, :prepare_turn, fn %Run{task_id: task_id} ->
      send(test_pid, {:prepared, task_id})
      "The branch is behind origin/main.\n\n"
    end)

    %{project: project, task: task, run: run, run_id: run_id}
  end

  test "sends the queued message and takes it off the run", %{run: run, run_id: run_id} do
    expect(Tools, :start_os_process, fn spawned, argv ->
      assert Enum.any?(argv, &(&1 =~ "Please also add a test"))
      refute Enum.any?(argv, &(&1 =~ "behind origin/main"))
      {:ok, %OsProcess{run: spawned}}
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: nil, status: :running} = Repo.reload!(run)
    assert_received {:run_changed, ^run_id}
    # Plan never commits, so its turn needs neither a fresh default branch nor the owner's key.
    refute_received {:prepared, _task_id}
  end

  test "each turn carries the prompt merged to the project's .rail/prompts at the time", %{
    project: project,
    run: run
  } do
    remote = create_temp_git_repo(prefix: "rail_dispatch_prompt_remote")
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/plan.md"), "From the repo.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    clone = create_temp_git_repo(prefix: "rail_dispatch_prompt_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])
    {:ok, _project} = Projects.update_project(system_scope(), project, %{clone_path: clone})

    expect(Tools, :start_os_process, fn spawned, argv ->
      assert ["--append-system-prompt", "From the repo."] in Enum.chunk_every(argv, 2, 1)
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
  end

  test "a turn with no prompt file in the project's repo carries the stored prompt", %{run: run} do
    expect(Tools, :start_os_process, fn spawned, argv ->
      assert ["--append-system-prompt", "You are the plan agent."] in Enum.chunk_every(argv, 2, 1)
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
  end

  test "a message to a Plan run spawns with Product, Designer and Architect as subagents", %{run: run} do
    expect(Tools, :start_os_process, fn spawned, argv ->
      [json] = for ["--agents", json] <- Enum.chunk_every(argv, 2, 1), do: json

      assert %{
               "product" => %{"prompt" => "You are the product agent." <> _product_rules},
               "designer" => %{"prompt" => "You are the design agent." <> _design_rules},
               "architect" => %{"prompt" => "You are the architect agent." <> _architect_rules}
             } = Jason.decode!(json)

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
  end

  # How the last turn ended is not how this one has ended, and a run left wearing
  # an error is a run nothing will ever latch as done.
  test "a person's message starts the count of CI failures sent back over", %{run: run} do
    {:ok, run} = Pipeline.update_run(run, %{ci_failure_streak: 3})

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
    assert %Run{ci_failure_streak: 0} = Repo.reload!(run)
  end

  test "the turn before this one takes its error with it", %{run: run} do
    {:ok, failed} = run |> Run.changeset(%{error: "Error: empty prompt", exit_code: 1}) |> Repo.update()

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %OsProcess{}} = dispatch_message(failed, async: false)
    assert %Run{error: nil, exit_code: nil} = Repo.reload!(failed)
  end

  # Subagents are a spawn flag, not part of the saved session, so the lead's every turn passes them again.
  test "a message to the Review lead spawns with the code reviewer, explorer, engineer and demo recorder", %{
    project: project,
    task: %Task{id: task_id} = task
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_dispatch_review_lead",
        pending_chat: "Check the empty state too",
        started_at: DateTime.utc_now()
      })

    expect(Tools, :start_os_process, fn spawned, argv ->
      [json] = for ["--agents", json] <- Enum.chunk_every(argv, 2, 1), do: json

      assert %{"code-reviewer" => %{}, "explorer" => %{}, "engineer" => %{}, "demo-recorder" => %{}} =
               Jason.decode!(json)

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
    assert_received {:prepared, ^task_id}
  end

  # The engineer's turn starts on a fresh default branch, committing as the ticket's owner.
  test "a message to a run that leads nobody spawns with no subagents", %{project: project, task: task} do
    {:ok, %Task{id: task_id} = task} = Pipeline.update_task(task, %{stage: :engineer})
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_dispatch_engineer",
        pending_chat: "Rename the button",
        started_at: DateTime.utc_now()
      })

    expect(Tools, :start_os_process, fn spawned, argv ->
      assert_received {:prepared, ^task_id}
      assert "The branch is behind origin/main.\n\nRename the button" in argv
      refute "--agents" in argv
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
  end

  test "a message that fails to spawn goes back on the run", %{run: run, run_id: run_id} do
    expect(Tools, :start_os_process, fn spawned, _argv -> {:error, {:spawn_failed, :enoent, spawned}} end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    assert {:error, {:spawn_failed, :enoent}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test"} = Repo.reload!(run)
    assert_received {:run_changed, ^run_id}
    assert [%RunEvent{line: "[rail] That message was not delivered: " <> _reason}] = Repo.all(RunEvent)
  end

  test "a message held back by disabled dispatch stays queued", %{run: run} do
    expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert {:error, :dispatch_disabled} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test"} = Repo.reload!(run)
  end

  # A worktree that cannot be made is the message never leaving, and the run has
  # to say so rather than look like it was delivered.
  test "a message with nowhere to run fails the run", %{run: run} do
    expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, :no_such_branch} end)

    assert {:error, {:worktree_failed, :no_such_branch}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test"} = Repo.reload!(run)
    assert [%RunEvent{line: "[rail] That message was not delivered: " <> _reason}] = Repo.all(RunEvent)
  end

  test "a run that is gone has nothing to dispatch", %{run: run} do
    Repo.delete!(run)

    assert {:error, :invalid_state} = dispatch_message(run, async: false)
  end

  # Two dispatches can reach one queued message - the human sending it now and
  # the exit of the turn they interrupted - and the one that arrives second finds
  # the row empty. Spawning an agent with no prompt is an error the run then
  # wears, so the second one sends nothing at all.
  test "a queue someone else already emptied spawns nothing", %{run: run} do
    {:ok, drained} = run |> Run.changeset(%{pending_chat: nil}) |> Repo.update()

    reject(&Tools.start_os_process/2)

    assert {:error, :nothing_queued} = dispatch_message(drained, async: false)
  end

  test "a worktree that still needs setting up gets that first, with the message left queued", %{
    project: project,
    run: run
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{worktree_setup_script: "bin/setup"})

    reject(Tools, :start_os_process, 2)

    expect(Tools, :start_command_process, fn spawned, :setup, "./bin/setup", _opts ->
      {:ok, %OsProcess{kind: :setup, run: spawned}}
    end)

    assert {:ok, %OsProcess{kind: :setup}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test", status: :running} = Repo.reload!(run)
  end

  test "a setup that cannot start leaves the message queued and the run failed", %{project: project, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{worktree_setup_script: "bin/setup"})

    expect(Tools, :start_command_process, fn _run, :setup, _command, _opts -> {:error, :enoent} end)

    assert {:error, :worktree_setup_failed} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test", status: :failed} = Repo.reload!(run)
  end

  describe "a message to a Review lead whose round waits on a person" do
    setup %{project: project, task: task} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :review})
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

      {:ok, %Run{id: lead_id} = lead} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_dispatch_latched_lead",
          pending_chat: "Are you sure about the nil?",
          started_at: DateTime.utc_now()
        })

      %{lead: lead, lead_id: lead_id}
    end

    test "puts the run back in progress, so the turn it starts is read on its own", %{lead: lead, lead_id: lead_id} do
      expect(Tools, :start_os_process, fn %Run{id: ^lead_id, stage_outcome: :in_progress} = spawned, _argv ->
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %OsProcess{}} = dispatch_message(lead, async: false)
      assert %Run{stage_outcome: :in_progress, status: :running} = Repo.reload!(lead)
    end

    test "whose worktree setup cannot start reads failed, not done", %{project: project, lead: lead} do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{worktree_setup_script: "bin/setup"})

      expect(Tools, :start_command_process, fn _run, :setup, _command, _opts -> {:error, :enoent} end)

      assert {:error, :worktree_setup_failed} = dispatch_message(lead, async: false)
      assert :failed = lead |> Repo.reload!() |> Repo.preload(:questions) |> Run.state()
    end
  end

  test "a message to a done Plan run leaves it done", %{run: run} do
    {:ok, done} = Pipeline.update_run(run, %{stage_outcome: :done})
    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %OsProcess{}} = dispatch_message(done, async: false)
    assert %Run{stage_outcome: :done} = Repo.reload!(done)
  end
end
