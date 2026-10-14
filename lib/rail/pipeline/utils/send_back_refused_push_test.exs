defmodule Rail.Pipeline.Utils.SendBackRefusedPushTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.SendBackRefusedPush

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sbp_1", "identifier" => "SBP-1", "title" => "Send Back Push"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Send Back Push"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    run = fn stage ->
      {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

      {:ok, run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          conversation_id: "sess_send_back_push",
          started_at: DateTime.utc_now()
        })

      Repo.preload(run, [:task, :role])
    end

    %{task: task, run: run}
  end

  test "a rewritten branch goes back to the engineer to merge what was pushed back in", %{task: task, run: run} do
    %Run{id: run_id} = engineer = run.(:engineer)
    test_pid = self()

    expect(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, ["-p", prompt | _rest] ->
      send(test_pid, {:resumed, prompt})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert %Run{id: ^run_id} = send_back_refused_push(engineer, :history_rewritten)

    assert_received {:resumed, prompt}
    assert prompt =~ "The branch rewrote commits already pushed to origin/#{task.worktree_name}, so Rail did not push it."
    assert prompt =~ "A rebase, an amend or a reset of a pushed commit rewrites history, which is never done here."
    assert prompt =~ "Merge `origin/#{task.worktree_name}`, which Rail has just fetched, into the branch"

    assert [%{line: "[rail] The branch rewrote commits already pushed" <> said}] = Pipeline.list_run_events(engineer)
    assert said =~ "It went back to the engineer."
  end

  # Those commits are someone's work, so the engineer merges them in rather than pushing over them.
  test "a branch someone pushed to outside Rail goes back to the engineer to merge those commits in", %{
    task: task,
    run: run
  } do
    %Run{id: run_id} = engineer = run.(:engineer)

    expect(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Someone pushed to origin/#{task.worktree_name} outside Rail, so Rail did not push over it."
      assert prompt =~ "Those commits are someone's work, so they are kept."
      {:ok, %OsProcess{run: spawned}}
    end)

    assert %Run{id: ^run_id} = send_back_refused_push(engineer, :pushed_outside_rail)
  end

  test "an agent that cannot be resumed says why on the run", %{run: run} do
    engineer = run.(:engineer)
    expect(Tools, :start_os_process, fn spawned, _argv -> {:error, {:spawn_failed, :enoent, spawned}} end)

    assert %Run{} = send_back_refused_push(engineer, :history_rewritten)

    expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert %Run{status: :finished, error: "Dispatch is off, so the engineer was not resumed."} =
             send_back_refused_push(engineer, :history_rewritten)
  end
end
