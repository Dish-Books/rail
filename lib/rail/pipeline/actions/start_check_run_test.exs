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
      Map.new([:qa, :review, :demo], fn stage ->
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
      assert prompt =~ "Keep the screen states current"
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

  test "QA re-checks a later round's own change, not every acceptance criterion", %{task: task, runs: runs} do
    base = task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "the fix"])
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter by vendor.", approved_at: DateTime.utc_now()})

    Repo.insert!(%Round{
      task_id: task.id,
      number: 2,
      plan: "Guard the nil.",
      base_head: base,
      approved_at: DateTime.utc_now()
    })

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "This is round 2: the first round checked every acceptance criterion"
      assert prompt =~ "in one line for each area of criteria left out, why the round's change cannot reach it"
      assert prompt =~ "checks for what the round's diff touches"

      assert prompt =~
               "Read the whole change with `git diff origin/main...HEAD`, and this round's own change with `git diff #{base}..HEAD`."

      refute prompt =~ "every acceptance criterion gets at least one check"
      refute prompt =~ "This round merged the default branch in"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.qa)
  end

  test "a round that merged the default branch points its checkers at what the merge changed in the branch's files",
       %{task: task, runs: runs} do
    base = task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(task.worktree_path, ["checkout", "--quiet", "-b", "upstream"])
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "the default branch's work"])
    git!(task.worktree_path, ["checkout", "--quiet", "main"])
    git!(task.worktree_path, ["merge", "--quiet", "--no-ff", "--no-edit", "upstream"])

    Repo.insert!(%Round{
      task_id: task.id,
      number: 2,
      plan: "Merge it in.",
      base_head: base,
      approved_at: DateTime.utc_now()
    })

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "You are the code reviewer for the change below"
      assert prompt =~ "the whole change, and this round's own change when one is named below"

      assert prompt =~
               "This round merged the default branch in, so most of its own change is work the default branch already holds: what the merge changed in the files the branch had touched before it is `git diff #{base}..HEAD -- $(git diff --name-only origin/main...#{base})`."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.review)

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "checks for what the merge changed in the files the branch had touched"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.qa)
  end

  test "QA walks every acceptance criterion again when the round's start is no longer in the branch", %{
    task: task,
    runs: runs
  } do
    base = task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(task.worktree_path, ["commit", "--quiet", "--amend", "--allow-empty", "-m", "initial commit, rebased"])

    Repo.insert!(%Round{
      task_id: task.id,
      number: 2,
      plan: "Guard the nil.",
      base_head: base,
      approved_at: DateTime.utc_now()
    })

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "every acceptance criterion gets at least one check quoting it in `criterion`"
      assert prompt =~ "This is round 2. Read the change with `git diff origin/main...HEAD`."
      refute prompt =~ "this round's own change with"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.qa)
  end

  # The states keep their keys across rounds, so each one's pictures line up commit by commit.
  # A state nothing has touched since its picture is left as it is, so a round off screen reshoots nothing.
  test "QA shoots every state first, then only those a commit since each one's picture can alter", %{
    task: task,
    runs: runs
  } do
    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "No state has been shot yet: shoot every state the change affects."
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.qa)

    folder = Path.join([task.scratch_path, "qa", "screens", "file-list"])
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "1.jpg"), "jpeg")

    {:ok, %{commit: commit}} =
      Pipeline.save_screen(task, %{key: "file-list", label: "File list", file: "screens/file-list/1.jpg"})

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Read what changed since with `git diff <commit> HEAD`"
      assert prompt =~ "Leave a state nothing has touched as it is."
      assert prompt =~ "`file-list` (File list) on #{String.slice(commit, 0, 7)}."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_check_run(runs.qa)
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
