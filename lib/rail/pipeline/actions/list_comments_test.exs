defmodule Rail.Pipeline.Actions.ListCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{project: project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)

    task = learnings_task(project, "LCM-1", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, plan_role} = Roles.get_role(project_id: project.id, stage: :plan)
    {:ok, lead_role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, plan_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: plan_role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_lcm_plan",
        started_at: DateTime.utc_now()
      })

    {:ok, lead_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead_role.id,
        status: :finished,
        conversation_id: "sess_lcm_lead",
        started_at: DateTime.utc_now()
      })

    {:ok, _ticket} = Pipeline.save_plan(task, %{title: "Comments", description: "- List every comment."})
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "screens", "tray"]))
    File.write!(Path.join([task.scratch_path, "qa", "screens", "tray", "1.jpg"]), "jpeg")
    {:ok, _shot} = Pipeline.save_screen(task, %{key: "tray", label: "Tray", file: "screens/tray/1.jpg"})

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

    {:ok, _pass} = Pipeline.save_review(task)
    test_pid = self()

    # A message to an idle run resumes it in the background, which each test that sends one waits for, so it never
    # outlives the test's stubs; what is sent after it waits on the run.
    stub(Tools, :start_os_process, fn spawned, _argv ->
      send(test_pid, {:resumed, spawned.id})
      {:ok, %OsProcess{run: spawned}}
    end)

    {:ok, ada} =
      Users.register_oauth_user(%{github_id: "gh_lcm_ada", login: "ada-lcm", name: "Ada", email: "ada-lcm@example.com"})

    {:ok, grace} =
      Users.register_oauth_user(%{github_id: "gh_lcm_grace", login: "grace-lcm", email: "grace-lcm@example.com"})

    ticket = %{
      target: :ticket,
      element_kind: :list_item,
      element_label: "Item 1",
      element_occurrence: 1,
      element_text: "List every comment.",
      body: "Say which comments."
    }

    %{
      task: task,
      plan_run: plan_run,
      lead_run: lead_run,
      finding: finding,
      ticket: ticket,
      ada: user_scope(user: ada),
      grace: user_scope(user: grace)
    }
  end

  test "a plan comment round is listed as its comments, never as a message, and answers and Rail's notes are left out",
       %{task: task, plan_run: plan_run, ticket: ticket, ada: %{user: %{id: ada_id}} = ada, grace: grace} do
    {:ok, %PlanComment{id: comment_id}} = Pipeline.create_plan_comment(ada, plan_run, ticket)
    {:ok, :sent, _run} = Pipeline.send_plan_comments(ada, plan_run)
    assert_receive {:resumed, _run_id}

    question = Repo.insert!(%Question{task_id: task.id, run_id: plan_run.id, prompt: "Which list?"})
    {:ok, _answered} = Pipeline.answer_question(ada, question, "The task's.")
    {:ok, _delivery, _run} = Pipeline.send_answers(ada, Repo.reload!(plan_run))
    Pipeline.append_run_events(plan_run.id, nil, ["[human] Finish review: nothing was ruled Fix."])
    {:ok, _delivery, _run} = Pipeline.send_message(ada, Repo.reload!(plan_run), "Keep the numbering.")

    assert [
             %{kind: :plan, id: ^comment_id, user: %{id: ^ada_id}, comment: %PlanComment{status: :sent}},
             %{kind: :message, user: %{id: ^ada_id}, comment: %{body: "Keep the numbering.", role: %{stage: :plan}}}
           ] = Pipeline.list_comments(grace, task)
  end

  test "a design pick is not listed, while a typed message that starts with the same words is",
       %{task: task, plan_run: plan_run, ada: %{user: %{id: ada_id}} = ada, grace: grace} do
    {:ok, :sent, _run} = Pipeline.send_message(ada, Repo.reload!(plan_run), "I picked One list (one-list).")
    assert_receive {:resumed, _run_id}

    {:ok, _delivery, _run} =
      Pipeline.send_message(ada, Repo.reload!(plan_run), "I picked One list (one-list). Fold the tray too.")

    assert [
             %{
               kind: :message,
               user: %{id: ^ada_id},
               comment: %{body: "I picked One list (one-list). Fold the tray too."}
             }
           ] = Pipeline.list_comments(grace, task)
  end

  test "a Review Send is listed as its comments to everyone, never as a message",
       %{task: task, lead_run: lead_run, ada: %{user: %{id: ada_id}} = ada, grace: grace} do
    {:ok, %{id: screen_id}} = Pipeline.create_screen_comment(ada, task, %{"key" => "tray", "body" => "Fold it."})
    {:ok, _resumed} = Pipeline.start_fix_round(ada, lead_run)

    assert [%{kind: :screen, id: ^screen_id, user: %{id: ^ada_id}, comment: %ScreenComment{status: :sent}}] =
             Pipeline.list_comments(grace, task)
  end

  test "another person's unsent comments never appear, while the reader's own do",
       %{task: task, plan_run: plan_run, finding: finding, ticket: ticket, ada: ada, grace: grace} do
    diff = %{path: "lib/a.ex", line_kind: :added, line: 1, line_text: "x", filter: :branch}
    piece = %{"finding_id" => finding.id, "piece" => "fix"}

    for scope <- [ada, grace] do
      {:ok, _diff} = Pipeline.create_diff_comment(scope, task, Map.put(diff, :body, scope.user.login))
      {:ok, _plan} = Pipeline.create_plan_comment(scope, plan_run, %{ticket | body: scope.user.login})
      {:ok, _screen} = Pipeline.create_screen_comment(scope, task, %{"key" => "tray", "body" => scope.user.login})
      {:ok, _finding} = Pipeline.create_finding_comment(scope, task, Map.put(piece, "body", scope.user.login))
    end

    assert [:diff, :plan, :screen, :finding] = Enum.map(Pipeline.list_comments(ada, task), & &1.kind)
    assert ["ada-lcm"] = ada |> Pipeline.list_comments(task) |> Enum.map(& &1.comment.body) |> Enum.uniq()
    assert ["grace-lcm"] = grace |> Pipeline.list_comments(task) |> Enum.map(& &1.comment.body) |> Enum.uniq()
  end

  test "two lines sent in one message read as one entry, while two messages, or one in each of two runs at once, read
        as two",
       %{task: task, plan_run: plan_run, lead_run: lead_run, ada: %{user: %{id: ada_id}} = ada} do
    [%{id: first_id, inserted_at: at} | _second] =
      Pipeline.append_run_events(plan_run.id, nil, ["[human:#{ada_id}] One.", "[human:#{ada_id}]   Two."])

    [%{id: later_id}] = Pipeline.append_run_events(plan_run.id, nil, ["[human:#{ada_id}] Later."])
    [%{id: lead_id}] = Pipeline.append_run_events(lead_run.id, nil, ["[human:usr_gone] At once."])
    Repo.update_all(from(e in RunEvent, where: e.id == ^lead_id), set: [inserted_at: at])

    assert [
             %{id: ^first_id, at: ^at, user: %{id: ^ada_id}, comment: %{body: "One.\n  Two."}},
             %{id: ^lead_id, at: ^at, user: nil, comment: %{body: "At once.", role: %{stage: :review_lead}}},
             %{id: ^later_id, comment: %{body: "Later."}}
           ] = Pipeline.list_comments(ada, task)
  end

  test "a line from an agent that only looks like a message is not one", %{task: task, plan_run: plan_run, ada: ada} do
    Pipeline.append_run_events(plan_run.id, nil, ["[human:] Not a sender.", "say [human:usr_x] mid-line"])

    assert Pipeline.list_comments(ada, task) == []
  end
end
