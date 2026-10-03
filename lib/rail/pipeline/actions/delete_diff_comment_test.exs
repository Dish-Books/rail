defmodule Rail.Pipeline.Actions.DeleteDiffCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dcm_delete_1", "identifier" => "DCD-1", "title" => "Diff Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Diff Comments"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_dcd_ada", login: "ada", email: "ada@example.com"})
    {:ok, grace} = Users.register_oauth_user(%{github_id: "gh_dcd_grace", login: "grace", email: "grace@example.com"})
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

    %{task: task, ada: ada, grace: user_scope(user: grace), comment: comment}
  end

  test "the person who wrote it removes it", %{task: task, ada: ada, comment: comment} do
    assert {:ok, %DiffComment{}} = Pipeline.delete_diff_comment(ada, comment)
    assert Pipeline.list_diff_comments(ada, task) == []
  end

  # The same person, in another tab drawn before the first removed it.
  test "removing a comment already gone is still done", %{task: task, ada: ada, comment: comment} do
    {:ok, _removed} = Pipeline.delete_diff_comment(ada, comment)

    assert {:ok, %DiffComment{}} = Pipeline.delete_diff_comment(ada, comment)
    assert Pipeline.list_diff_comments(ada, task) == []
  end

  test "nobody else can remove it", %{task: task, ada: ada, grace: grace, comment: comment} do
    assert_raise FunctionClauseError, fn -> Pipeline.delete_diff_comment(grace, comment) end
    assert [%DiffComment{}] = Pipeline.list_diff_comments(ada, task)
  end

  test "a sent or resolved comment stays, and offers no removal", %{
    project: project,
    task: task,
    ada: ada,
    comment: comment
  } do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_delete_diff_comment",
        started_at: DateTime.utc_now()
      })

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, :sent, _run} = Pipeline.send_diff_comments(ada, run)
    [sent] = Pipeline.list_diff_comments(ada, task)
    {:ok, resolved} = Pipeline.set_diff_comment_resolved(ada, sent, true)

    assert_raise FunctionClauseError, fn -> Pipeline.delete_diff_comment(ada, sent) end
    assert_raise FunctionClauseError, fn -> Pipeline.delete_diff_comment(ada, resolved) end

    # A tab drawn before the send still holds it as unsent.
    assert {:ok, %DiffComment{}} = Pipeline.delete_diff_comment(ada, comment)
    assert [%DiffComment{status: :resolved}] = Pipeline.list_diff_comments(ada, task)
  end

  test "tells the author's pages on the task", %{task: %{id: task_id}, ada: ada, comment: comment} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}:#{ada.user.id}")

    {:ok, _removed} = Pipeline.delete_diff_comment(ada, comment)

    assert_receive {:diff_comments_changed, ^task_id}
  end
end
