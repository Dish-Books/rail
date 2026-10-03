defmodule Rail.Pipeline.Actions.SetDiffCommentResolvedTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dcm_resolve_1", "identifier" => "DCR-1", "title" => "Diff Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Diff Comments"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_resolve_diff_comments",
        started_at: DateTime.utc_now()
      })

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_dcr_ada", login: "ada", email: "ada@example.com"})
    {:ok, grace} = Users.register_oauth_user(%{github_id: "gh_dcr_grace", login: "grace", email: "grace@example.com"})
    ada = user_scope(user: ada)

    {:ok, comment} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/a.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name it."
      })

    %{task: task, run: run, ada: ada, grace: user_scope(user: grace), comment: comment}
  end

  describe "a sent comment" do
    setup %{task: task, run: run, ada: ada} do
      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
      {:ok, :sent, _run} = Pipeline.send_diff_comments(ada, run)
      [sent] = Pipeline.list_diff_comments(ada, task)

      %{sent: sent}
    end

    test "is resolved by its author, and every page on the task hears of it", %{
      task: %{id: task_id} = task,
      ada: ada,
      grace: grace,
      sent: %{id: id} = sent
    } do
      Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}")

      assert {:ok, %DiffComment{id: ^id, status: :resolved}} = Pipeline.set_diff_comment_resolved(ada, sent, true)
      assert_receive {:diff_comments_changed, ^task_id}
      assert [%DiffComment{id: ^id, status: :resolved}] = Pipeline.list_diff_comments(grace, task)
    end

    test "unresolved goes back to sent without telling the engineer", %{task: task, run: run, ada: ada, sent: sent} do
      {:ok, resolved} = Pipeline.set_diff_comment_resolved(ada, sent, true)
      events = Pipeline.list_run_events(run)

      assert {:ok, %DiffComment{status: :sent}} = Pipeline.set_diff_comment_resolved(ada, resolved, false)
      assert [%DiffComment{status: :sent}] = Pipeline.list_diff_comments(ada, task)
      assert Pipeline.list_run_events(run) == events
      assert {:error, :nothing_to_send} = Pipeline.send_diff_comments(ada, run)
    end

    # Two tabs clicking at once agree on where it ends up.
    test "resolving one already resolved is a harmless repeat", %{ada: ada, sent: sent} do
      {:ok, _resolved} = Pipeline.set_diff_comment_resolved(ada, sent, true)

      assert {:ok, %DiffComment{status: :resolved}} = Pipeline.set_diff_comment_resolved(ada, sent, true)
    end

    test "nobody else can resolve it", %{task: task, ada: ada, grace: grace, sent: sent} do
      assert_raise FunctionClauseError, fn -> Pipeline.set_diff_comment_resolved(grace, sent, true) end
      assert [%DiffComment{status: :sent}] = Pipeline.list_diff_comments(ada, task)
    end
  end

  test "an unsent comment cannot be resolved", %{task: %{id: task_id} = task, ada: ada, comment: comment} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}:#{ada.user.id}")

    assert {:error, :not_found} = Pipeline.set_diff_comment_resolved(ada, comment, true)
    assert {:error, :not_found} = Pipeline.set_diff_comment_resolved(ada, comment, false)
    assert [%DiffComment{status: :unsent}] = Pipeline.list_diff_comments(ada, task)
    refute_receive {:diff_comments_changed, ^task_id}
  end

  test "a comment that is gone cannot be resolved", %{ada: ada, comment: comment} do
    {:ok, _removed} = Pipeline.delete_diff_comment(ada, comment)

    assert {:error, :not_found} = Pipeline.set_diff_comment_resolved(ada, %{comment | status: :sent}, true)
  end
end
