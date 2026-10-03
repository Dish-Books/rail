defmodule Rail.Pipeline.Actions.ListDiffCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
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

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_dcl_ada", login: "ada", email: "ada@example.com"})
    {:ok, grace} = Users.register_oauth_user(%{github_id: "gh_dcl_grace", login: "grace", email: "grace@example.com"})

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
    project: project,
    task: task,
    ada: ada,
    grace: grace
  } do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_list_diff_comments",
        started_at: DateTime.utc_now()
      })

    comment = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "def feature, do: :ok", filter: :branch}
    {:ok, %{id: resolved_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Resolved."))
    {:ok, %{id: sent_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Sent."))
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, :sent, _run} = Pipeline.send_diff_comments(ada, run)
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
               %DiffComment{id: ^resolved_id, status: :resolved, user: %{login: "ada"}},
               %DiffComment{id: ^sent_id, status: :sent, user: %{login: "ada"}}
             ] = Pipeline.list_diff_comments(reader, task)
    end
  end

  test "a scope with nobody in it has none while nothing is sent", %{task: task} do
    assert Pipeline.list_diff_comments(system_scope(), task) == []
  end
end
