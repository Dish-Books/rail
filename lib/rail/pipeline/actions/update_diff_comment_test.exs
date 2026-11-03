defmodule Rail.Pipeline.Actions.UpdateDiffCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Users

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dcm_update_1", "identifier" => "DCU-1", "title" => "Diff Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Diff Comments"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_dcu_ada",
        login: "ada-update-diff-comment",
        email: "ada-update-diff-comment@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_dcu_grace",
        login: "grace-update-diff-comment",
        email: "grace-update-diff-comment@example.com"
      })

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

  test "the author changes an unsent comment's text and their tabs hear of it", %{
    task: %{id: task_id} = task,
    comment: comment,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}:#{ada.user.id}")

    assert {:ok, %DiffComment{body: "Say why."}} = Pipeline.update_diff_comment(ada, comment, %{"body" => "Say why."})
    assert [%DiffComment{body: "Say why."}] = Pipeline.list_diff_comments(ada, task)
    assert_received {:diff_comments_changed, ^task_id}
  end

  test "a blank text is refused and the comment keeps its own", %{
    task: task,
    comment: %{body: text} = comment,
    ada: ada
  } do
    assert {:error, %Ecto.Changeset{}} = Pipeline.update_diff_comment(ada, comment, %{"body" => "  "})
    assert [%DiffComment{body: ^text}] = Pipeline.list_diff_comments(ada, task)
  end

  # A send that got there first, or another tab, leaves the row as it is.
  test "a comment sent or removed meanwhile keeps the text it had", %{comment: %{id: id, body: text} = comment, ada: ada} do
    {1, nil} = Repo.update_all(from(c in DiffComment, where: c.id == ^id), set: [status: :sent])

    assert {:error, :not_found} = Pipeline.update_diff_comment(ada, comment, %{"body" => "Say why."})
    assert %DiffComment{status: :sent, body: ^text} = Repo.get!(DiffComment, id)

    Repo.delete_all(from(c in DiffComment, where: c.id == ^id))
    assert {:error, :not_found} = Pipeline.update_diff_comment(ada, comment, %{"body" => "Say why."})
  end

  test "refuses another person's comment, and a sent one", %{comment: comment, ada: ada, grace: grace} do
    assert_raise FunctionClauseError, fn -> Pipeline.update_diff_comment(grace, comment, %{"body" => "Mine now."}) end

    assert_raise FunctionClauseError, fn ->
      Pipeline.update_diff_comment(ada, %{comment | status: :sent}, %{"body" => "Say why."})
    end

    assert Repo.get!(DiffComment, comment.id).body == comment.body
  end
end
