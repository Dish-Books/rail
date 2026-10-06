defmodule Rail.Pipeline.Actions.DeletePlanCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Users

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :plan)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_pcm_delete_1", "identifier" => "PCD-1", "title" => "Plan Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Plan Comments"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
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
        conversation_id: "sess_delete_plan_comment",
        started_at: DateTime.utc_now()
      })

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_pcdelete_ada", login: "ada", email: "ada@example.com"})

    {:ok, grace} =
      Users.register_oauth_user(%{github_id: "gh_pcdelete_grace", login: "grace", email: "grace@example.com"})

    attrs = %{
      target: :design,
      option_key: "waiting-lanes",
      selector: "#group-by-project",
      element_text: "Group by project",
      element_tag: "label",
      capture: %{html: ~s(<label id="group-by-project">Group by project</label>), width: 160, height: 20},
      body: "Turn this on by default."
    }

    %{
      task: task,
      role: role,
      run: run,
      dir: dir,
      attrs: attrs,
      ada: user_scope(user: ada),
      grace: user_scope(user: grace)
    }
  end

  test "the author removes an unsent comment and their tabs hear of it", %{
    task: %{id: task_id} = task,
    run: run,
    ada: ada,
    attrs: attrs
  } do
    {:ok, comment} = Pipeline.create_plan_comment(ada, run, attrs)
    Phoenix.PubSub.subscribe(Rail.PubSub, "plan_comments:#{task_id}:#{ada.user.id}")

    assert {:ok, %PlanComment{}} = Pipeline.delete_plan_comment(ada, comment)
    assert Pipeline.list_plan_comments(ada, task) == []
    assert_receive {:plan_comments_changed, ^task_id}
  end

  test "an unsent comment is removed also while Plan cannot be messaged", %{task: task, run: run, ada: ada, attrs: attrs} do
    {:ok, comment} = Pipeline.create_plan_comment(ada, run, attrs)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: nil])

    assert {:ok, %PlanComment{}} = Pipeline.delete_plan_comment(ada, comment)
    assert Pipeline.list_plan_comments(ada, task) == []
  end

  test "a comment another tab just sent stays, and another person's cannot be removed", %{
    task: task,
    run: run,
    ada: ada,
    grace: grace,
    attrs: attrs
  } do
    {:ok, %{id: id} = comment} = Pipeline.create_plan_comment(ada, run, attrs)
    Repo.update_all(from(c in PlanComment, where: c.id == ^id), set: [status: :sent])

    assert {:ok, %PlanComment{}} = Pipeline.delete_plan_comment(ada, comment)
    assert %PlanComment{status: :sent} = Repo.get!(PlanComment, id)

    {:ok, adas} = Pipeline.create_plan_comment(ada, run, attrs)
    assert_raise FunctionClauseError, fn -> Pipeline.delete_plan_comment(grace, adas) end
    assert [%PlanComment{}] = Pipeline.list_plan_comments(ada, task)
  end
end
