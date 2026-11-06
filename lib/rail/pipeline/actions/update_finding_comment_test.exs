defmodule Rail.Pipeline.Actions.UpdateFindingCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "UFC-1", :review)
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

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_ufc_ada",
        login: "ada-update-finding-comment",
        email: "ada-update-finding-comment@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_ufc_grace",
        login: "grace-update-finding-comment",
        email: "grace-update-finding-comment@example.com"
      })

    {:ok, comment} =
      Pipeline.create_finding_comment(user_scope(user: ada), task, %{
        "finding_id" => finding.id,
        "piece" => "problem",
        "body" => "Hi."
      })

    %{task: task, comment: comment, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "the author changes an unsent comment's text and their tabs hear of it", %{
    task: %{id: task_id} = task,
    comment: comment,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "finding_comments:#{task_id}:#{ada.user.id}")

    assert {:ok, %FindingComment{body: "Say why."}} =
             Pipeline.update_finding_comment(ada, comment, %{"body" => " Say why. "})

    assert [%FindingComment{body: "Say why."}] = Pipeline.list_finding_comments(ada, task)
    assert_received {:finding_comments_changed, ^task_id}
  end

  test "a blank text is refused and the comment keeps its own", %{
    task: task,
    comment: %{body: text} = comment,
    ada: ada
  } do
    assert {:error, %Ecto.Changeset{}} = Pipeline.update_finding_comment(ada, comment, %{"body" => "  "})
    assert [%FindingComment{body: ^text}] = Pipeline.list_finding_comments(ada, task)
  end

  # A send that got there first, or another tab, leaves the row as it is.
  test "a comment sent or removed meanwhile keeps the text it had", %{comment: %{id: id, body: text} = comment, ada: ada} do
    {1, nil} = Repo.update_all(from(c in FindingComment, where: c.id == ^id), set: [status: :sent])

    assert {:error, :not_found} = Pipeline.update_finding_comment(ada, comment, %{"body" => "Say why."})
    assert %FindingComment{status: :sent, body: ^text} = Repo.get!(FindingComment, id)

    Repo.delete_all(from(c in FindingComment, where: c.id == ^id))
    assert {:error, :not_found} = Pipeline.update_finding_comment(ada, comment, %{"body" => "Say why."})
  end

  test "refuses another person's comment, and a sent one", %{comment: comment, ada: ada, grace: grace} do
    assert_raise FunctionClauseError, fn -> Pipeline.update_finding_comment(grace, comment, %{"body" => "Mine now."}) end

    assert_raise FunctionClauseError, fn ->
      Pipeline.update_finding_comment(ada, %{comment | status: :sent}, %{"body" => "Say why."})
    end

    assert Repo.get!(FindingComment, comment.id).body == comment.body
  end
end
