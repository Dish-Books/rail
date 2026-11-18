defmodule Rail.Pipeline.Actions.StartCuratorRunTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    stub(Git, :branch_fingerprint, fn _path -> nil end)
    task = learnings_task(project, "SCR-1", :finalize)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, curator} = Roles.get_role(project_id: project.id, stage: :curator)
    {:ok, run} = Pipeline.start_or_resume_run(task, curator, nil)
    %{run: run, dir: Path.join(task.scratch_path, "learnings")}
  end

  test "a first pass spawns the curator's role on a new conversation, pointed at the task's files", %{
    run: run,
    dir: dir
  } do
    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt, "--model", "claude-opus-5-5" | rest] ->
      assert prompt =~ dir
      assert "You are the curator agent." in rest
      refute "--resume" in rest
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_curator_run(run)
  end

  test "a later pass resumes the conversation on a brief of its own", %{run: run} do
    {:ok, resumed} = Pipeline.update_run(run, %{conversation_id: "sess_curator"})
    test = self()

    expect(Tools, :start_os_process, 2, fn %Run{} = spawned, ["-p", prompt | rest] ->
      send(test, {:spawned, prompt, rest})
      {:ok, %OsProcess{run: spawned}}
    end)

    {:ok, _first} = Pipeline.start_curator_run(run)
    {:ok, _again} = Pipeline.start_curator_run(%{resumed | task: run.task, role: run.role}, new_pass: true)
    assert_received {:spawned, first, _first_rest}
    assert_received {:spawned, again, ["--model", _model | again_rest]}
    assert ["--resume", "sess_curator"] = Enum.take(again_rest, -2)
    assert again != first
  end

  test "a Retry resumes the conversation on the first pass's brief", %{run: run} do
    {:ok, resumed} = Pipeline.update_run(run, %{conversation_id: "sess_curator"})
    test = self()

    expect(Tools, :start_os_process, 2, fn %Run{} = spawned, ["-p", prompt | rest] ->
      send(test, {:spawned, prompt, rest})
      {:ok, %OsProcess{run: spawned}}
    end)

    {:ok, _first} = Pipeline.start_curator_run(run)
    {:ok, _retried} = Pipeline.start_curator_run(%{resumed | task: run.task, role: run.role}, fresh: false)
    assert_received {:spawned, first, _first_rest}
    assert_received {:spawned, retried, ["--model", _model | retried_rest]}
    assert ["--resume", "sess_curator"] = Enum.take(retried_rest, -2)
    assert retried == first
  end
end
