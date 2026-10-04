defmodule Rail.Pipeline.Actions.SendDiffCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
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

  test "an idle engineer gets every comment in one message, and they stay on the diff, sent", %{
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
                 +     where(query, [i], i.status != :paid)
                 Void invoices are not overdue.

                 lib/ledger/billing/invoice_query.ex, removed line 28
                 -   defp newest_first(query)
                 Keep this ordering.

                 lib/ledger_web/live/invoice_live/index.ex, line 39
                       filters = Filters.parse(params)
                 An unknown status should fall back to All.\
                 """,
                 "\n"
               ),
               &"[human:#{ada.user.id}] #{&1}"
             )

    assert [%DiffComment{status: :sent}, %DiffComment{status: :sent}, %DiffComment{status: :sent}] =
             Pipeline.list_diff_comments(ada, task)
  end

  test "only the comments not sent yet are sent, and once each", %{task: task, run: run, ada: ada} do
    comment = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "def feature, do: :ok", filter: :branch}
    {:ok, _first} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "First round, one."))
    {:ok, _second} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "First round, two."))
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, :sent, _run} = Pipeline.send_diff_comments(ada, run)
    {:ok, %{id: new_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Second round."))
    sent_before = length(Pipeline.list_run_events(run))

    assert {:ok, :sent, %Run{}} = Pipeline.send_diff_comments(ada, run)

    later = run |> Pipeline.list_run_events() |> Enum.drop(sent_before) |> Enum.map_join("\n", & &1.line)
    assert later =~ "1 comment on the diff"
    assert later =~ "Second round."
    refute later =~ "First round"

    assert [%DiffComment{status: :sent}, %DiffComment{status: :sent}, %DiffComment{id: ^new_id, status: :sent}] =
             Pipeline.list_diff_comments(ada, task)
  end

  # A second tab, or a second click, finds every comment already sent.
  test "sending again with nothing new sends nothing", %{task: task, run: run, ada: ada} do
    {:ok, _only} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/a.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name it."
      })

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    {:ok, :sent, _run} = Pipeline.send_diff_comments(ada, run)
    events = Pipeline.list_run_events(run)

    assert {:error, :nothing_to_send} = Pipeline.send_diff_comments(ada, run)
    assert Pipeline.list_run_events(run) == events
  end

  test "a working engineer gets them queued for when its turn ends", %{task: task, run: run, ada: ada} do
    {:ok, running} = Pipeline.update_run(run, %{status: :running})

    {:ok, _only} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/a.ex",
        line_kind: :added,
        line: 3,
        line_text: "x = 1   ",
        filter: :branch,
        body: "Name it."
      })

    assert {:ok, :queued, %Run{pending_chat: "1 comment on the diff\n\nlib/a.ex, line 3\n+ x = 1\nName it."}} =
             Pipeline.send_diff_comments(ada, running)

    assert [%DiffComment{status: :sent}] = Pipeline.list_diff_comments(ada, task)
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

    comment = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "def feature, do: :ok", filter: :branch}
    {:ok, %{id: first_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Name it."))
    {:ok, %{id: second_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "And this."))
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task.id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task.id}:#{ada.user.id}")

    assert {:error, :chat_unavailable} = Pipeline.send_diff_comments(ada, fresh)

    assert [%DiffComment{id: ^first_id, status: :unsent}, %DiffComment{id: ^second_id, status: :unsent}] =
             Pipeline.list_diff_comments(ada, task)

    refute_receive {:diff_comments_changed, _task_id}
  end

  test "another person's comments are neither sent nor marked sent", %{task: task, run: run, ada: ada, grace: grace} do
    comment = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "def feature, do: :ok", filter: :branch}

    {:ok, %{id: adas_id}} = Pipeline.create_diff_comment(ada, task, Map.put(comment, :body, "Ada's"))
    {:ok, %{id: graces_id}} = Pipeline.create_diff_comment(grace, task, Map.put(comment, :body, "Grace's"))

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_diff_comments(ada, run)

    lines = run |> Pipeline.list_run_events() |> Enum.map_join("\n", & &1.line)
    assert lines =~ "Ada's"
    refute lines =~ "Grace's"

    assert [%DiffComment{id: ^adas_id, status: :sent}, %DiffComment{id: ^graces_id, status: :unsent}] =
             Pipeline.list_diff_comments(grace, task)
  end

  # Everyone sees a sent comment, so every page on the task hears of the send.
  test "tells every page on the task once the comments are sent, not before", %{
    task: %{id: task_id} = task,
    run: run,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "diff_comments:#{task_id}")

    assert {:error, :nothing_to_send} = Pipeline.send_diff_comments(ada, run)
    refute_receive {:diff_comments_changed, ^task_id}

    {:ok, _saved} =
      Pipeline.create_diff_comment(ada, task, %{
        path: "lib/a.ex",
        line_kind: :added,
        line: 1,
        line_text: "def feature, do: :ok",
        filter: :branch,
        body: "Name it."
      })

    # An unsent comment is its author's alone, so only their own pages hear of it.
    refute_receive {:diff_comments_changed, ^task_id}
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_diff_comments(ada, run)
    assert_receive {:diff_comments_changed, ^task_id}
  end

  describe "the code around each line" do
    test "each comment quotes its block with its line marked, and becomes a provisional rule once sent", %{
      task: task,
      run: run,
      ada: ada
    } do
      {:ok, %{id: comment_id}} =
        Pipeline.create_diff_comment(ada, task, %{
          path: "test/a_test.exs",
          line_kind: :added,
          line: 4,
          line_text: "Repo.insert!(row)",
          context_text: "  + row = %Row{}\n> + Repo.insert!(row)\n    end",
          filter: :branch,
          body: "Use the factory here."
        })

      stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, :sent, %Run{}} = Pipeline.send_diff_comments(ada, run)

      tag = "[human:#{ada.user.id}]"

      assert Enum.map(Pipeline.list_run_events(run), & &1.line) == [
               "#{tag} 1 comment on the diff",
               "#{tag} ",
               "#{tag} test/a_test.exs, line 4",
               "#{tag}   + row = %Row{}",
               "#{tag} > + Repo.insert!(row)",
               "#{tag}     end",
               "#{tag} Use the factory here."
             ]

      assert [
               %Observation{
                 source_id: ^comment_id,
                 excerpt: "  + row = %Row{}\n> + Repo.insert!(row)\n    end",
                 learning: %{status: :provisional, rule: "Use the factory here.", roles: [:engineer, :review]}
               }
             ] =
               Repo.all(from o in Observation, where: o.task_id == ^task.id, preload: :learning)
    end

    test "comments that cannot go out are not learned from", %{task: task, run: run, ada: ada} do
      {:ok, _comment} =
        Pipeline.create_diff_comment(ada, task, %{
          path: "a.ex",
          line_kind: :added,
          line: 1,
          line_text: "x",
          filter: :branch,
          body: "No"
        })

      {:ok, _run} = Pipeline.update_run(run, %{status: :finished})
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [conversation_id: nil])

      assert {:error, :chat_unavailable} = Pipeline.send_diff_comments(ada, Repo.reload!(run))
      assert [] = Repo.all(from o in Observation, where: o.task_id == ^task.id)
    end
  end
end
