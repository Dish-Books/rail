defmodule Rail.Pipeline.Actions.SendDiffCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
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
            "issue" => %{"id" => "lin_dcm_send_1", "identifier" => "DCS-1", "title" => "Diff Comments"}
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
        conversation_id: "sess_send_diff_comments",
        started_at: DateTime.utc_now()
      })

    {:ok, ada} = Users.register_oauth_user(%{github_id: "gh_dcs_ada", login: "ada", email: "ada@example.com"})
    {:ok, grace} = Users.register_oauth_user(%{github_id: "gh_dcs_grace", login: "grace", email: "grace@example.com"})

    %{task: task, role: role, run: run, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "an idle engineer gets every comment in one message, and they leave the diff", %{
    task: task,
    run: run,
    ada: ada
  } do
    {:ok, _added} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/ledger/billing/invoice_query.ex",
        line_kind: :added,
        line: 38,
        line_text: "    where(query, [i], i.status != :paid)",
        filter: :branch,
        body: "Void invoices are not overdue."
      })

    {:ok, _deleted} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/ledger/billing/invoice_query.ex",
        line_kind: :deleted,
        line: 28,
        line_text: "  defp newest_first(query)",
        filter: :branch,
        body: "Keep this ordering."
      })

    {:ok, _context} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/ledger_web/live/invoice_live/index.ex",
        line_kind: :context,
        line: 39,
        line_text: "    filters = Filters.parse(params)",
        filter: :branch,
        body: "An unknown status should fall back to All."
      })

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_diff_comments(ada, run)

    assert Enum.map(Pipeline.list_run_events(run), & &1.line) ==
             Enum.map(
               String.split(
                 """
                 3 comments on the diff

                 lib/ledger/billing/invoice_query.ex, line 38
                 + where(query, [i], i.status != :paid)
                 Void invoices are not overdue.

                 lib/ledger/billing/invoice_query.ex, removed line 28
                 - defp newest_first(query)
                 Keep this ordering.

                 lib/ledger_web/live/invoice_live/index.ex, line 39
                   filters = Filters.parse(params)
                 An unknown status should fall back to All.\
                 """,
                 "\n"
               ),
               &"[human] #{&1}"
             )

    assert Pipeline.list_diff_comments(ada, task) == []
  end

  test "a working engineer gets them queued for when its turn ends", %{task: task, run: run, ada: ada} do
    {:ok, running} = Pipeline.update_run(run, %{status: :running})

    {:ok, _only} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/a.ex",
        line_kind: :added,
        line: 3,
        line_text: "x = 1",
        filter: :branch,
        body: "Name it."
      })

    assert {:ok, :queued, %Run{pending_chat: "1 comment on the diff\n\nlib/a.ex, line 3\n+ x = 1\nName it."}} =
             Pipeline.send_diff_comments(ada, running)

    assert Pipeline.list_diff_comments(ada, task) == []
  end

  test "with nothing unsent nothing is sent", %{run: run, ada: ada} do
    assert {:error, :nothing_to_send} = Pipeline.send_diff_comments(ada, run)
    assert Pipeline.list_run_events(run) == []
  end

  test "an engineer with no conversation to send to keeps the comments unsent", %{
    task: task,
    role: role,
    ada: ada
  } do
    {:ok, fresh} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    {:ok, comment} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/a.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name it."
      })

    assert {:error, :chat_unavailable} = Pipeline.send_diff_comments(ada, fresh)
    assert [^comment] = Pipeline.list_diff_comments(ada, task)
  end

  test "another person's comments are neither sent nor removed", %{task: task, run: run, ada: ada, grace: grace} do
    comment = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "def feature, do: :ok", filter: :branch}

    {:ok, _adas} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Ada's"))
    {:ok, graces} = Pipeline.create_diff_comment(grace, task, Map.put(comment, :body, "Grace's"))

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_diff_comments(ada, run)

    lines = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)
    assert lines =~ "Ada's"
    refute lines =~ "Grace's"
    assert [^graces] = Pipeline.list_diff_comments(grace, task)
  end
end
