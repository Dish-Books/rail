defmodule Rail.Pipeline.Actions.CheckPreviewTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Clients.Preview, as: Client
  alias Rail.Pipeline.Schemas.Preview
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools

  setup %{project: project} do
    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{
        preview_enabled: true,
        preview_url_template: "https://pr-{pr_number}.preview.example.com",
        preview_login_path: "/dev/login"
      })

    task = learnings_task(project, "CPV-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # Git is only asked through Rail.Git, so the worktree is a directory whose HEAD file names the commit it is on.
    worktree = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, "HEAD"), "aaa111")
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree, pr_number: 7})

    stub(Git, :branch_fingerprint, fn path ->
      %{head_sha: File.read!(Path.join(path, "HEAD")), dirty_digest: "clean"}
    end)

    # The tab a push replaced is reloaded through Rail's browser, which is not run here.
    test = self()

    stub(Tools, :send_browser_input, fn %Task{id: task_id}, name, event ->
      send(test, {:browser_input, task_id, name, event})
      :ok
    end)

    %{task: task, worktree: worktree}
  end

  test "a project without previews, or a task without a pull request, has none to check", %{task: task} do
    {:ok, no_pr} = Pipeline.update_task(task, %{pr_number: nil})
    assert {:error, :no_pr} = Pipeline.check_preview(no_pr)

    {:ok, _off} = Projects.update_project(system_scope(), task.project, %{preview_enabled: false})
    assert {:error, :disabled} = Pipeline.check_preview(task)
    assert Pipeline.get_preview(task) == nil
  end

  test "a deployment serving another commit, answering otherwise or not at all is still deploying", %{task: task} do
    Req.Test.expect(Client, fn conn ->
      assert conn.host == "pr-7.preview.example.com"
      Req.Test.json(conn, %{"sha" => "older"})
    end)

    assert {:ok, %Preview{status: :deploying, url: "https://pr-7.preview.example.com", live_sha: nil, live_at: nil}} =
             Pipeline.check_preview(task)

    Req.Test.expect(Client, &Plug.Conn.send_resp(&1, 502, "Bad gateway"))
    assert {:ok, %Preview{status: :deploying}} = Pipeline.check_preview(task)

    Req.Test.expect(Client, &Req.Test.transport_error(&1, :nxdomain))
    assert {:ok, %Preview{status: :deploying, checked_at: %DateTime{}}} = Pipeline.check_preview(task)
  end

  test "a deployment serving the worktree's head commit is live, and is what the task's preview reads", %{task: task} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"sha" => "aaa111"}))

    assert {:ok, %Preview{id: id, status: :live, live_sha: "aaa111", live_at: %DateTime{}}} =
             Pipeline.check_preview(task)

    assert %Preview{id: ^id, status: :live} = Pipeline.get_preview(task)
  end

  # Nothing is asked of the deployment: with no worktree there is no head commit for it to serve.
  test "a task whose worktree is gone, or that was cleaned up, has its preview gone", %{task: task, worktree: worktree} do
    {:ok, cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})
    assert {:ok, %Preview{status: :gone, live_sha: nil}} = Pipeline.check_preview(cleaned)

    File.rm_rf!(worktree)
    assert {:ok, %Preview{status: :gone}} = Pipeline.check_preview(task)
  end

  test "a change is said to the task's page, and a look that finds the same thing says nothing", %{task: task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "previews:#{task.id}")

    Req.Test.expect(Client, 2, &Req.Test.json(&1, %{"sha" => "older"}))
    {:ok, %Preview{id: id}} = Pipeline.check_preview(task)
    assert_received {:preview_changed, %Preview{id: ^id, status: :deploying}}

    {:ok, _same} = Pipeline.check_preview(task)
    refute_received {:preview_changed, _preview}

    Req.Test.expect(Client, &Req.Test.json(&1, %{"sha" => "aaa111"}))
    {:ok, _live} = Pipeline.check_preview(task)
    assert_received {:preview_changed, %Preview{id: ^id, status: :live, live_sha: "aaa111"}}
  end

  # The commit last live is kept through the deploy, so the one after it going live reloads the tab on the old one.
  test "a push keeps the commit last live while it deploys, and reloads the app's tab once it goes live", %{
    task: %{id: task_id} = task,
    worktree: worktree
  } do
    Req.Test.expect(Client, 2, &Req.Test.json(&1, %{"sha" => "aaa111"}))
    {:ok, %Preview{status: :live, live_at: first_live}} = Pipeline.check_preview(task)
    {:ok, %Preview{status: :live, live_at: ^first_live}} = Pipeline.check_preview(task)
    refute_received {:browser_input, _task_id, _name, _event}

    File.write!(Path.join(worktree, "HEAD"), "bbb222")
    Req.Test.expect(Client, &Req.Test.json(&1, %{"sha" => "aaa111"}))

    assert {:ok, %Preview{status: :deploying, live_sha: "aaa111", live_at: ^first_live}} = Pipeline.check_preview(task)
    refute_received {:browser_input, _task_id, _name, _event}

    Req.Test.expect(Client, &Req.Test.json(&1, %{"sha" => "bbb222"}))

    assert {:ok, %Preview{status: :live, live_sha: "bbb222", live_at: second_live}} = Pipeline.check_preview(task)
    assert DateTime.after?(second_live, first_live)
    assert_received {:browser_input, ^task_id, "app", %{"kind" => "navigate", "to" => "reload"}}
  end

  test "the first time it is live, the Review lead is asked once to set up demo examples there", %{
    project: project,
    task: task
  } do
    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{preview_database: "Example PR {pr_number}"})

    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    {:ok, %Run{id: engineer_run}} = Pipeline.start_or_resume_run(task, engineer, task.worktree_path)
    # Working, so what Rail says waits for its turn to end rather than starting one.
    {:ok, %Run{id: lead_run}} = Pipeline.start_or_resume_run(task, lead, task.worktree_path)

    Req.Test.expect(Client, 2, &Req.Test.json(&1, %{"sha" => "aaa111"}))

    assert {:ok, %Preview{status: :live, seeded_at: %DateTime{} = seeded_at}} = Pipeline.check_preview(task)

    assert %Run{pending_chat: said} = Repo.get!(Run, lead_run)
    assert said =~ "The preview of this pull request is live at https://pr-7.preview.example.com,"
    assert said =~ "signed in at https://pr-7.preview.example.com/dev/login."
    assert said =~ "Its data is the database `Example PR 7` in your database tools."
    assert %Run{pending_chat: nil} = Repo.get!(Run, engineer_run)

    assert {:ok, %Preview{seeded_at: ^seeded_at}} = Pipeline.check_preview(task)
    assert %Run{pending_chat: ^said} = Repo.get!(Run, lead_run)
  end

  test "a preview with no database the lead reaches is announced without one", %{project: project, task: task} do
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    {:ok, %Run{id: lead_run}} = Pipeline.start_or_resume_run(task, lead, task.worktree_path)

    Req.Test.expect(Client, &Req.Test.json(&1, %{"sha" => "aaa111"}))
    assert {:ok, %Preview{seeded_at: %DateTime{}}} = Pipeline.check_preview(task)

    assert %Run{pending_chat: said} = Repo.get!(Run, lead_run)
    assert said =~ "signed in at https://pr-7.preview.example.com/dev/login. Set up demo examples there"
    refute said =~ "database"
  end

  # Until the lead has a conversation to be asked in, the next look asks again.
  test "without a Review lead to ask, or one that cannot be asked yet, nobody is told and the next look tries again",
       %{project: project, task: task} do
    Req.Test.expect(Client, 3, &Req.Test.json(&1, %{"sha" => "aaa111"}))
    assert {:ok, %Preview{status: :live, seeded_at: nil}} = Pipeline.check_preview(task)

    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    {:ok, run} = Pipeline.start_or_resume_run(task, lead, task.worktree_path)
    # Stopped before it ever held a conversation, so there is nothing to resume it into.
    {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished, conversation_id: nil})
    assert {:ok, %Preview{seeded_at: nil}} = Pipeline.check_preview(task)

    {:ok, _resumable} = Pipeline.update_run(Repo.reload!(run), %{status: :running})
    assert {:ok, %Preview{seeded_at: %DateTime{}}} = Pipeline.check_preview(task)
  end
end
