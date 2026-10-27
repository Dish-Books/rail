defmodule Rail.Pipeline.Actions.ListDiffCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Users

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, 2, fn conn ->
      id = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dcm_list_#{id}", "identifier" => "DCL-#{id}", "title" => "Diff Comments"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Diff Comments"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    {:ok, other_issue} = Issues.create_issue(system_scope(), project, %{description: "Other Diff Comments"})
    {:ok, other_task} = Pipeline.create_task(other_issue, :engineer)
    on_exit(fn -> Enum.each([task, other_task], &File.rm_rf(&1.scratch_path)) end)

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_dcl_ada",
        login: "ada-list-diff-comments",
        email: "ada-list-diff-comments@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_dcl_grace",
        login: "grace-list-diff-comments",
        email: "grace-list-diff-comments@example.com"
      })

    %{task: task, other_task: other_task, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "lists only this person's unsent comments on this task, by file and then as written", %{
    task: task,
    other_task: other_task,
    ada: ada,
    grace: grace
  } do
    attrs = %{line_kind: :added, line: 1, line_text: "def feature, do: :ok", filter: :branch}

    {:ok, second_file} = Pipeline.create_diff_comment(ada, task, Map.merge(attrs, %{path: "lib/b.ex", body: "b"}))
    {:ok, first} = Pipeline.create_diff_comment(ada, task, Map.merge(attrs, %{path: "lib/a.ex", body: "a1"}))
    {:ok, second} = Pipeline.create_diff_comment(ada, task, Map.merge(attrs, %{path: "lib/a.ex", body: "a2"}))
    {:ok, _graces} = Pipeline.create_diff_comment(grace, task, Map.merge(attrs, %{path: "lib/a.ex", body: "g"}))
    {:ok, _elsewhere} = Pipeline.create_diff_comment(ada, other_task, Map.merge(attrs, %{path: "lib/a.ex", body: "o"}))

    assert Enum.map(Pipeline.list_diff_comments(ada, task), & &1.id) == [first.id, second.id, second_file.id]
  end

  # The database's collation would put acme_web before acme/; the diff's file list and the sent message do not.
  test "files go in byte order for every reader", %{task: task, ada: ada} do
    attrs = %{line_kind: :added, line: 1, line_text: "x", filter: :branch, body: "b"}
    {:ok, %{id: web_id}} = Pipeline.create_diff_comment(ada, task, Map.put(attrs, :path, "lib/acme_web/live/tray.ex"))
    {:ok, %{id: worker_id}} = Pipeline.create_diff_comment(ada, task, Map.put(attrs, :path, "lib/acme/worker.ex"))

    assert [%DiffComment{id: ^worker_id}, %DiffComment{id: ^web_id}] =
             Pipeline.list_diff_comments(ada, task, unsent: true)

    # As the Review tray's Send leaves them.
    Repo.update_all(from(c in DiffComment, where: c.task_id == ^task.id and c.status == :unsent), set: [status: :sent])

    assert [%DiffComment{id: ^worker_id}, %DiffComment{id: ^web_id}] = Pipeline.list_diff_comments(system_scope(), task)
  end

  test "a different person sees none of their unsent comments", %{task: task, ada: ada, grace: grace} do
    {:ok, _adas} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/a.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name it."
      })

    assert Pipeline.list_diff_comments(grace, task) == []
  end

  test "sent and resolved comments are listed for everyone, unsent ones only for their author", %{
    task: task,
    ada: ada,
    grace: grace
  } do
    comment = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "def feature, do: :ok", filter: :branch}
    {:ok, %{id: resolved_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Resolved."))
    {:ok, %{id: sent_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Sent."))
    # As the Review tray's Send leaves them.
    Repo.update_all(from(c in DiffComment, where: c.task_id == ^task.id and c.status == :unsent), set: [status: :sent])
    {:ok, %{id: unsent_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Unsent."))
    [to_resolve | _rest] = Pipeline.list_diff_comments(ada, task)
    {:ok, _resolved} = Pipeline.set_diff_comment_resolved(ada, to_resolve, true)

    assert [
             %DiffComment{id: ^resolved_id, status: :resolved},
             %DiffComment{id: ^sent_id, status: :sent},
             %DiffComment{id: ^unsent_id, status: :unsent}
           ] = Pipeline.list_diff_comments(ada, task)

    for reader <- [grace, system_scope()] do
      assert [
               %DiffComment{id: ^resolved_id, status: :resolved, user: %{login: "ada-list-diff-comments"}},
               %DiffComment{id: ^sent_id, status: :sent, user: %{login: "ada-list-diff-comments"}}
             ] = Pipeline.list_diff_comments(reader, task)
    end
  end

  # The Review tray holds only what the reader's Send would send.
  test "the unsent filter lists only the reader's unsent comments", %{
    task: task,
    ada: ada,
    grace: grace
  } do
    comment = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "x", filter: :branch}
    {:ok, _sent} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Sent."))
    # As the Review tray's Send leaves them.
    Repo.update_all(from(c in DiffComment, where: c.task_id == ^task.id and c.status == :unsent), set: [status: :sent])
    {:ok, %{id: unsent_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Unsent."))
    {:ok, _theirs} = Pipeline.create_diff_comment(grace, task, Map.put(comment, :body, "Grace's."))

    assert [%DiffComment{id: ^unsent_id, user: %{login: "ada-list-diff-comments"}}] =
             Pipeline.list_diff_comments(ada, task, unsent: true)

    assert [%DiffComment{body: "Grace's."}] = Pipeline.list_diff_comments(grace, task, unsent: true)
    assert [%DiffComment{body: "Sent."}, %DiffComment{body: "Unsent."}] = Pipeline.list_diff_comments(ada, task)
  end

  test "a scope with nobody in it has none while nothing is sent", %{task: task} do
    assert Pipeline.list_diff_comments(system_scope(), task) == []
  end
end
