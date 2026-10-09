defmodule RailWeb.Live.EngineerStageTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Users

  setup %{conn: conn, project: project} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "est-1-#{id}",
        login: "dana-#{id}",
        name: "Dana",
        email: "dana-#{id}@est.example"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    remote = create_temp_git_repo(prefix: "rail_est_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "rows.ex"), Enum.map_join(1..10, "", &"line #{&1}\n"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the engineer's work"])
    git!(repo, ["push", "--set-upstream", "origin", "feature"])

    task = learnings_task(project, "EST-1")
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: repo})

    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_est",
        started_at: DateTime.utc_now()
      })

    %{conn: log_in_user(conn, user), task: task, repo: repo}
  end

  test "once the task is in Review, the Engineer tab offers no Commit, CI, send or chat", %{
    conn: conn,
    task: task,
    repo: repo
  } do
    File.write!(Path.join(repo, "rows.ex"), "edited\n")
    {:ok, _review} = Pipeline.update_task(task, %{stage: :review})

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}?tab=rol_test_seed_engineer")

    assert has_element?(view, "#engineer-stage")
    refute has_element?(view, "#commit-work")
    refute has_element?(view, "#run-ci")
    refute has_element?(view, "#send-to-review")
    refute has_element?(view, "#chat-input")
    assert has_element?(view, "#conversation-closed", "The work is in Review now, so this conversation is closed")
  end
end
