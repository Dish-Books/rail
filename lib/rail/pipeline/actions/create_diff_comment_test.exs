defmodule Rail.Pipeline.Actions.CreateDiffCommentTest do
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
            "issue" => %{"id" => "lin_dcm_create_1", "identifier" => "DCM-1", "title" => "Diff Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Diff Comments"})
    {:ok, %{id: task_id} = task} = Pipeline.create_task(issue, :engineer)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, %{id: user_id} = ada} =
      Users.register_oauth_user(%{github_id: "gh_dcm_ada", login: "ada", email: "ada@example.com"})

    %{task: task, task_id: task_id, user_id: user_id, ada: user_scope(user: ada)}
  end

  test "saves the comment as the person who wrote it, on the task", %{
    task: task,
    task_id: task_id,
    user_id: user_id,
    ada: ada
  } do
    assert {:ok,
            %DiffComment{
              task_id: ^task_id,
              user_id: ^user_id,
              path: "lib/ledger/billing/invoice_query.ex",
              line_kind: :deleted,
              line: 28,
              line_text: "  defp newest_first(query)",
              filter: :uncommitted,
              body: "Keep this ordering."
            }} =
             Pipeline.create_diff_comment(ada, task, %{
               "path" => "lib/ledger/billing/invoice_query.ex",
               "line_kind" => "deleted",
               "line" => 28,
               "line_text" => "  defp newest_first(query)",
               "filter" => "uncommitted",
               "body" => "Keep this ordering."
             })
  end

  test "a blank line can be commented on", %{task: task, ada: ada} do
    attrs = %{path: "lib/a.ex", line_kind: :added, line: 3, line_text: "", filter: :branch, body: "Drop this gap."}

    assert {:ok, %DiffComment{line_text: ""}} = Pipeline.create_diff_comment(ada, task, attrs)
  end

  test "a blank comment is not saved", %{task: task, ada: ada} do
    attrs = %{path: "lib/a.ex", line_kind: :added, line: 3, line_text: "x", filter: :branch, body: "   "}

    assert {:error, changeset} = Pipeline.create_diff_comment(ada, task, attrs)
    assert %{body: ["can't be blank"]} = errors_on(changeset)
  end

  test "a comment is on a numbered line", %{task: task, ada: ada} do
    attrs = %{path: "lib/a.ex", line_kind: :added, line: 0, line_text: "x", filter: :branch, body: "Why?"}

    assert {:error, changeset} = Pipeline.create_diff_comment(ada, task, attrs)
    assert %{line: ["must be greater than 0"]} = errors_on(changeset)
  end

  test "cannot be filed as someone else or on another task", %{
    task: task,
    task_id: task_id,
    user_id: user_id,
    ada: ada
  } do
    attrs = %{
      task_id: "tsk_someone_elses",
      user_id: "usr_someone_else",
      path: "lib/a.ex",
      line_kind: :context,
      line: 3,
      line_text: "x",
      filter: :branch,
      body: "Why?"
    }

    assert {:ok, %DiffComment{task_id: ^task_id, user_id: ^user_id}} = Pipeline.create_diff_comment(ada, task, attrs)
  end

  # Every page the author has open on the task shows what Send would send.
  test "tells the author's pages on the task, and nobody else's", %{
    task: task,
    task_id: task_id,
    user_id: user_id,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}:#{user_id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}:usr_someone_else")
    attrs = %{path: "lib/a.ex", line_kind: :added, line: 3, line_text: "x", filter: :branch, body: "Why?"}

    {:ok, _saved} = Pipeline.create_diff_comment(ada, task, attrs)
    assert_receive {:diff_comments_changed, ^task_id}
    refute_receive {:diff_comments_changed, ^task_id}

    {:error, _blank} = Pipeline.create_diff_comment(ada, task, %{attrs | body: " "})
    refute_receive {:diff_comments_changed, ^task_id}
  end
end
