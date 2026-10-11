defmodule Rail.Pipeline.Actions.DeleteFindingCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "DFC-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, finding} =
      Pipeline.save_finding(task, %{
        key: "nil-crash",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Nil crashes the page",
        problem: "It crashes.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard it.",
        why: "It crashes.",
        rule: "Every caller handles nil.",
        severity: :major,
        recommendation: :fix,
        places: [%{file: "lib/a.ex", line: 3}],
        evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
      })

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_dfc_ada", login: "ada", email: "ada@example.com"})
    {:ok, grace} = Users.register_oauth_user(%{github_id: "gh_dfc_grace", login: "grace", email: "grace@example.com"})

    {:ok, comment} =
      Pipeline.create_finding_comment(user_scope(user: ada), task, %{
        "finding_id" => finding.id,
        "piece" => "problem",
        "body" => "Hi."
      })

    %{task: task, comment: comment, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "removes the author's own unsent comment and tells their pages", %{
    task: %{id: task_id} = task,
    comment: comment,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "finding_comments:#{task_id}:#{ada.user.id}")

    assert {:ok, %FindingComment{}} = Pipeline.delete_finding_comment(ada, comment)
    assert Pipeline.list_finding_comments(ada, task) == []
    assert_received {:finding_comments_changed, ^task_id}
  end

  # A send that got there first, or another tab, leaves the row as it is.
  test "leaves a comment that was sent meanwhile", %{comment: %{id: id} = comment, ada: ada} do
    {1, nil} = Repo.update_all(from(c in FindingComment, where: c.id == ^id), set: [status: :sent])

    assert {:ok, _comment} = Pipeline.delete_finding_comment(ada, comment)
    assert %FindingComment{status: :sent} = Repo.get!(FindingComment, id)
  end

  test "refuses another person's comment, and a sent one", %{comment: comment, ada: ada, grace: grace} do
    assert_raise FunctionClauseError, fn -> Pipeline.delete_finding_comment(grace, comment) end
    assert_raise FunctionClauseError, fn -> Pipeline.delete_finding_comment(ada, %{comment | status: :sent}) end
    assert Repo.get!(FindingComment, comment.id)
  end
end
