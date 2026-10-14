defmodule Rail.Pipeline.Actions.StartCheckRunTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "SCR-1", :review)
    worktree = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    runs =
      Map.new([:qa, :review, :screens, :demo], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)
        {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree, fresh: true)
        {stage, %{run | role: role}}
      end)

    %{task: task, runs: runs}
  end

  test "QA is spawned fresh on its own model, told to drive its own browser and save a report", %{
    task: task,
    runs: runs
  } do
    {:ok, _saved} = Pipeline.save_report(task, :engineer, "Guarded the nil in the action.")

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt, "--model", "claude-opus-5-5" | _rest] = argv ->
      refute "--resume" in argv
      refute "--agents" in argv
      assert prompt =~ "You are QA for the change below"
      assert prompt =~ "yours is named `qa`"
      assert prompt =~ "Save your report with `save_report` before you end your turn."
      assert prompt =~ "<report from=\"engineer\">\nGuarded the nil in the action.\n</report>"
      assert prompt =~ "There is no approved plan for this round, so the ticket below is the whole specification."
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.qa)
    assert File.dir?(Path.join([task.scratch_path, "qa", "evidence"]))
    assert File.dir?(Path.join(task.scratch_path, "demo"))
  end

  test "the code reviewer reads the branch against the round's approved plan, and drives no browser", %{
    task: task,
    runs: runs
  } do
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter by vendor.", approved_at: DateTime.utc_now()})

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "You are the code reviewer for the change below"
      assert prompt =~ "This is round 1. Read the change with `git diff origin/main...HEAD`."
      assert prompt =~ "Filter by vendor."
      refute prompt =~ "browser_connect"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.review)
  end

  # The states keep their keys across rounds, so each one's pictures line up commit by commit.
  test "the screenshots agent chooses the keys on the first round and shoots the same ones after", %{
    task: task,
    runs: runs
  } do
    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "You photograph every screen state the change below affects"
      assert prompt =~ "No state has been shot yet, so the keys are yours to choose"
      assert prompt =~ "yours is named `screens`"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.screens)

    folder = Path.join([task.scratch_path, "qa", "screens", "file-list"])
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "1.jpg"), "jpeg")
    {:ok, _shot} = Pipeline.save_screen(task, %{key: "file-list", label: "File list", file: "screens/file-list/1.jpg"})

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~
               "Shoot each again under the same `key`, and add any the change now affects: `file-list` (File list)."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.screens)
  end

  test "the demo recorder films one walkthrough in its own browser and saves it", %{runs: runs} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "You record the demo of the change below"
      assert prompt =~ "yours is named `demo`"
      assert prompt =~ "Call `save_demo` straight after the last beat"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.demo)
  end
end
