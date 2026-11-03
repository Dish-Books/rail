defmodule Rail.Pipeline.Actions.UpdatePlanCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Roles
  alias Rail.Users

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_pcm_update_1", "identifier" => "PCD-1", "title" => "Plan Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Plan Comments"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    # Git is stubbed, so the worktree is only ever looked for: a plain directory stands in for it.
    worktree_path = Path.join(System.tmp_dir!(), "rail_upc_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(worktree_path) end)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(
      Path.join(dir, "manifest.json"),
      ~s({"options": [{"key": "waiting-lanes", "title": "Lanes"}, {"key": "one-queue", "title": "Queue"}]})
    )

    File.write!(Path.join(dir, "picked"), "waiting-lanes")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_update_plan_comment",
        started_at: DateTime.utc_now()
      })

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_pcupdate_ada",
        login: "ada-update-plan-comment",
        email: "ada-update-plan-comment@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_pcupdate_grace",
        login: "grace-update-plan-comment",
        email: "grace-update-plan-comment@example.com"
      })

    attrs = %{
      target: :design,
      option_key: "waiting-lanes",
      selector: "#group-by-project",
      element_text: "Group by project",
      element_tag: "label",
      capture: %{html: ~s(<label id="group-by-project">Group by project</label>), width: 160, height: 20},
      body: "Turn this on by default."
    }

    {:ok, comment} = Pipeline.create_plan_comment(user_scope(user: ada), run, attrs)

    %{task: task, comment: comment, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "the author changes an unsent comment's text and their tabs hear of it", %{
    task: %{id: task_id} = task,
    comment: comment,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{ada.user.id}")

    assert {:ok, %PlanComment{body: "Say why."}} = Pipeline.update_plan_comment(ada, comment, %{"body" => " Say why. "})
    assert [%PlanComment{body: "Say why."}] = Pipeline.list_plan_comments(ada, task)
    assert_received {:plan_comments_changed, ^task_id}
  end

  test "a blank text is refused and the comment keeps its own", %{
    task: task,
    comment: %{body: text} = comment,
    ada: ada
  } do
    assert {:error, %Ecto.Changeset{}} = Pipeline.update_plan_comment(ada, comment, %{"body" => "  "})
    assert [%PlanComment{body: ^text}] = Pipeline.list_plan_comments(ada, task)
  end

  # A send that got there first, or another tab, leaves the row as it is.
  test "a comment sent or removed meanwhile keeps the text it had", %{comment: %{id: id, body: text} = comment, ada: ada} do
    {1, nil} = Repo.update_all(from(c in PlanComment, where: c.id == ^id), set: [status: :sent])

    assert {:error, :not_found} = Pipeline.update_plan_comment(ada, comment, %{"body" => "Say why."})
    assert %PlanComment{status: :sent, body: ^text} = Repo.get!(PlanComment, id)

    Repo.delete_all(from(c in PlanComment, where: c.id == ^id))
    assert {:error, :not_found} = Pipeline.update_plan_comment(ada, comment, %{"body" => "Say why."})
  end

  test "refuses another person's comment, and a sent one", %{comment: comment, ada: ada, grace: grace} do
    assert_raise FunctionClauseError, fn -> Pipeline.update_plan_comment(grace, comment, %{"body" => "Mine now."}) end

    assert_raise FunctionClauseError, fn ->
      Pipeline.update_plan_comment(ada, %{comment | status: :sent}, %{"body" => "Say why."})
    end

    assert Repo.get!(PlanComment, comment.id).body == comment.body
  end
end
