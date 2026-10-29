defmodule Rail.Pipeline.Actions.ListScreenCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)

    task = learnings_task(project, "LSM-1", :review)
    other = learnings_task(project, "LSM-2", :review)
    on_exit(fn -> Enum.each([task, other], &File.rm_rf(&1.scratch_path)) end)

    for %{scratch_path: scratch} = shot_task <- [task, other] do
      File.mkdir_p!(Path.join([scratch, "qa", "screens", "toolbar"]))
      File.write!(Path.join([scratch, "qa", "screens", "toolbar", "1.jpg"]), "jpeg")
      {:ok, _shot} = Pipeline.save_screen(shot_task, %{key: "toolbar", label: "Toolbar", file: "screens/toolbar/1.jpg"})
    end

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_lsm_ada",
        login: "ada-list-screen-comments",
        email: "ada-list-screen-comments@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_lsm_grace",
        login: "grace-list-screen-comments",
        email: "grace-list-screen-comments@example.com"
      })

    %{task: task, other: other, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "lists only the reader's unsent comments on the task, oldest first", %{
    task: task,
    other: other,
    ada: ada,
    grace: grace
  } do
    {:ok, %{id: first_id}} = Pipeline.create_screen_comment(ada, task, %{"key" => "toolbar", "body" => "First."})
    {:ok, %{id: second_id}} = Pipeline.create_screen_comment(ada, task, %{"key" => "toolbar", "body" => "Second."})
    {:ok, _theirs} = Pipeline.create_screen_comment(grace, task, %{"key" => "toolbar", "body" => "Grace's."})
    {:ok, _elsewhere} = Pipeline.create_screen_comment(ada, other, %{"key" => "toolbar", "body" => "Elsewhere."})

    assert [%ScreenComment{id: ^first_id}, %ScreenComment{id: ^second_id}] = Pipeline.list_screen_comments(ada, task)
    assert [%ScreenComment{body: "Grace's."}] = Pipeline.list_screen_comments(grace, task)
  end

  test "a sent comment is no longer listed", %{project: project, task: task, ada: ada} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, _comment} = Pipeline.create_screen_comment(ada, task, %{"key" => "toolbar", "body" => "Fold it."})
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, _resumed} = Pipeline.start_fix_round(ada, run)

    assert Pipeline.list_screen_comments(ada, task) == []
  end

  test "sent: true adds everyone's sent comments with their authors, never another person's unsent one", %{
    project: project,
    task: task,
    ada: %{user: %{id: ada_id}} = ada,
    grace: grace
  } do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    {:ok, _pass} = Pipeline.save_review(task)
    {:ok, %{id: sent_id}} = Pipeline.create_screen_comment(ada, task, %{"key" => "toolbar", "body" => "Fold it."})
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, _resumed} = Pipeline.start_fix_round(ada, run)
    {:ok, _unsent} = Pipeline.create_screen_comment(ada, task, %{"key" => "toolbar", "body" => "Not sent."})
    {:ok, %{id: graces_id}} = Pipeline.create_screen_comment(grace, task, %{"key" => "toolbar", "body" => "Mine."})

    assert [
             %ScreenComment{id: ^sent_id, status: :sent, user: %{id: ^ada_id}},
             %ScreenComment{id: ^graces_id, status: :unsent}
           ] = Pipeline.list_screen_comments(grace, task, sent: true)
  end
end
