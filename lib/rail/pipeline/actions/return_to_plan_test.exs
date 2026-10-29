defmodule Rail.Pipeline.Actions.ReturnToPlanTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Users

  @plan "## Implementation plan\n\nFilter by vendor."

  # Git is faked at its boundary: deleting a branch or a worktree, or making one, for real is for `Rail.Git`'s own
  # tests. The Planner's worktree is where it belongs, with nothing on disk to fingerprint.
  setup %{project: %{github_repo: repo, github_installation_id: installation_id} = project} do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :delete_remote_branch, fn _project, _branch -> :ok end)
    stub(Git, :remove_worktree, fn _repo_path, _worktree_path -> :ok end)
    stub(Git, :delete_branch, fn _repo_path, _branch -> :ok end)
    stub(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
    stub(Git, :branch_fingerprint, fn _worktree_path -> nil end)

    # Named per test, since a login two open sandboxes both insert waits on the other's.
    n = System.unique_integer([:positive])
    pull_path = "/repos/#{repo}/pulls/212"
    token_path = "/app/installations/#{installation_id}/access_tokens"

    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_return_1",
        identifier: "RTP-1",
        title: "Return me",
        state: :in_review,
        state_name: "In Review",
        branch_name: "rtp-1-return-me"
      })
      |> Repo.insert!()
      |> Repo.preload(:project)

    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    for folder <- ["design", "reviews", "qa"], do: File.mkdir_p!(Path.join(task.scratch_path, folder))
    File.write!(Path.join([task.scratch_path, "design", "picked"]), "rows")
    File.write!(Path.join([task.scratch_path, "reviews", "1.json"]), "{}")

    now = DateTime.utc_now()

    %Round{id: first_id} =
      Repo.insert!(%Round{
        task_id: task.id,
        number: 1,
        plan: @plan,
        approved_at: now,
        ready_at: now,
        base_head: "abc",
        head: "def",
        reviewed_at: now,
        finished_at: now,
        ticket: %Round.Ticket{title: "Return me", description: "The ticket."},
        design: %Round.Design{key: "rows", title: "Charts in the row"}
      })

    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    {:ok, plan_role} = Roles.get_role(project_id: project.id, stage: :plan)
    test_pid = self()

    Req.Test.stub(Client, fn
      %{method: "POST", request_path: ^token_path} = conn ->
        Req.Test.json(conn, %{"token" => "ghs_return"})

      %{method: "GET", request_path: ^pull_path} = conn ->
        Req.Test.json(conn, %{"number" => 212, "state" => "open"})

      %{method: "PATCH", request_path: ^pull_path} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:pull_request_changed, 212, Jason.decode!(body)})
        Req.Test.json(conn, %{"number" => 212, "state" => "closed"})
    end)

    {:ok, reader} =
      Users.register_oauth_user(%{
        github_id: "gh_return_#{n}",
        login: "return-reader-#{n}",
        email: "return-#{n}@example.com"
      })

    %{
      scope: user_scope(project_ids: [project.id]),
      reader: reader,
      reader_scope: user_scope(user: reader),
      issue: issue,
      task: task,
      token_path: token_path,
      lead: lead,
      plan_role: plan_role,
      first_id: first_id
    }
  end

  test "erases the work and the branch, keeps the ticket, design and plan, and starts the Planner on a new conversation in a worktree made again",
       %{
         scope: scope,
         task: task,
         issue: %Issue{id: issue_id, project: %{id: project_id, clone_path: clone}} = issue,
         lead: lead,
         plan_role: %{id: plan_role_id} = plan_role,
         reader: reader,
         reader_scope: reader_scope,
         first_id: first_id
       } do
    {:ok, %Task{id: task_id, worktree_name: branch, worktree_path: worktree_path} = task} =
      Pipeline.update_task(task, %{pr_number: 212})

    now = DateTime.utc_now()

    expect(Git, :delete_remote_branch, fn %{id: ^project_id}, ^branch -> :ok end)
    expect(Git, :remove_worktree, fn ^clone, ^worktree_path -> :ok end)
    expect(Git, :delete_branch, fn ^clone, ^branch -> :ok end)
    expect(Git, :get_or_create_worktree, fn %{id: ^project_id}, %Task{id: ^task_id} -> {:ok, worktree_path} end)

    {:ok, %Run{id: old_plan_id}} =
      Pipeline.create_run(%{
        task_id: task_id,
        role_id: plan_role.id,
        status: :finished,
        conversation_id: "sess_old_plan",
        started_at: now
      })

    {:ok, %Run{id: lead_id} = running} =
      Pipeline.create_run(%{task_id: task_id, role_id: lead.id, status: :running, started_at: now})

    {:ok, %{asked: [%Question{id: question_id}]}} = Pipeline.ask_questions(running, [%{"prompt" => "Which way?"}])
    Pipeline.append_run_events(lead_id, nil, ["Reviewing."])
    Repo.insert!(%Round{task_id: task_id, number: 2, plan: "Guard nil."})

    %Finding{id: finding_id} =
      Repo.insert!(%Finding{
        task_id: task_id,
        key: "a-nit",
        kind: :code,
        raised_by: :code_reviewer,
        round: 1,
        title: "A nit",
        severity: :nit,
        recommendation: :skip
      })

    %DiffComment{id: diff_comment_id} =
      Repo.insert!(%DiffComment{
        task_id: task_id,
        user_id: reader.id,
        path: "work.ex",
        line_kind: :added,
        filter: :branch,
        line: 1,
        body: "Why?"
      })

    %PlanComment{id: plan_comment_id} =
      Repo.insert!(%PlanComment{task_id: task_id, user_id: reader.id, target: :plan, body: "Shorter."})

    {:ok, _viewed} = Git.set_file_viewed(reader_scope, task, :diff, "work.ex", "digest", true)

    rule = learning(issue.project, %{rule: "Don't flag a nit", kind: :calibration})
    finding = %Finding{id: "fnd_return_1", title: "A nit", suppressed_by_id: rule.id}
    {:ok, [%Observation{id: observation_id}]} = Learnings.record_overrides(%{task | issue: issue}, [finding])

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Task{id: ^task_id, stage: :plan, pr_number: nil}} = Pipeline.return_to_plan(scope, task)

    assert_receive {:pull_request_changed, 212, %{"state" => "closed"}}
    assert_receive {:issue_changed, ^issue_id}

    assert [%Run{id: new_plan_id, role_id: ^plan_role_id, conversation_id: nil}] =
             Repo.all(from(r in Run, where: r.task_id == ^task_id))

    refute new_plan_id in [old_plan_id, lead_id]
    assert Repo.get(Question, question_id) == nil
    assert Repo.all(from(e in RunEvent, where: e.run_id == ^lead_id)) == []

    assert [
             %Round{
               id: ^first_id,
               plan: @plan,
               approved_at: nil,
               ready_at: nil,
               head: nil,
               reviewed_at: nil,
               finished_at: nil,
               ticket: %Round.Ticket{title: "Return me"},
               design: %Round.Design{key: "rows"}
             }
           ] = Repo.all(from(r in Round, where: r.task_id == ^task_id))

    assert Repo.get(Finding, finding_id) == nil
    assert Repo.get(DiffComment, diff_comment_id) == nil
    assert Repo.get(PlanComment, plan_comment_id) == nil
    assert Git.list_viewed_files(reader_scope, task, :diff) == %{}
    assert %Observation{} = Repo.get(Observation, observation_id)

    assert task.scratch_path |> File.ls!() |> Enum.reject(&(&1 == "streams")) == ["design"]
    assert File.read!(Path.join([task.scratch_path, "design", "picked"])) == "rows"

    assert %Issue{state: :in_progress, state_name: nil} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id, fields: ["state", "state_name"]})
  end

  test "keeps the run, file and comments of a custom stage before Plan, and erases one after it", %{
    scope: scope,
    task: task,
    issue: issue,
    reader: reader
  } do
    stages = [
      %IssueStage{stage: :custom, name: "Missing strings", prompt: "List the keys with no translation."},
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."},
      %IssueStage{stage: :review}
    ]

    issue |> Ecto.Changeset.change() |> Ecto.Changeset.put_embed(:stages, stages) |> Repo.update!()

    [{%Run{id: kept_run_id}, %PlanComment{id: kept_comment_id}}, {%Run{id: gone_run_id}, %PlanComment{id: gone_id}}] =
      for name <- ["Missing strings", "License check"] do
        {:ok, task} = Pipeline.update_task(task, %{stage: :custom, custom_stage: name})
        {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "#{name} found nothing."})
        {:ok, role} = Roles.get_custom_stage_role(task.project_id, name)

        {:ok, run} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: role.id,
            status: :finished,
            stage_outcome: :done,
            started_at: DateTime.utc_now()
          })

        comment =
          Repo.insert!(%PlanComment{
            task_id: task.id,
            user_id: reader.id,
            target: :output,
            custom_stage: name,
            status: :sent,
            body: "Say more."
          })

        {run, comment}
      end

    {:ok, task} = Pipeline.get_task(task.id)

    assert {:ok, %Task{stage: :plan, custom_stage: nil} = planning} = Pipeline.return_to_plan(scope, task)

    runs = Repo.all(from(r in Run, where: r.task_id == ^task.id))
    assert Enum.any?(runs, &(&1.id == kept_run_id))
    refute Enum.any?(runs, &(&1.id == gone_run_id))
    assert %PlanComment{custom_stage: "Missing strings"} = Repo.get(PlanComment, kept_comment_id)
    assert Repo.get(PlanComment, gone_id) == nil

    assert [%{name: "Missing strings", markdown: "Missing strings found nothing."}] =
             Pipeline.read_stage_outputs(planning)
  end

  test "a run started while GitHub closed the pull request is stopped before its row goes", %{
    scope: scope,
    task: task,
    issue: issue,
    token_path: token_path,
    lead: lead
  } do
    {:ok, %Task{id: task_id} = task} = Pipeline.update_task(task, %{pr_number: 212})
    pull_path = "/repos/#{issue.project.github_repo}/pulls/212"
    test_pid = self()

    # Runs in the test process, so the subscription is the test's.
    Req.Test.stub(Client, fn
      %{method: "POST", request_path: ^token_path} = conn ->
        Req.Test.json(conn, %{"token" => "ghs_return"})

      %{method: "GET", request_path: ^pull_path} = conn ->
        Req.Test.json(conn, %{"number" => 212, "state" => "open"})

      %{method: "PATCH", request_path: ^pull_path} = conn ->
        {:ok, %Run{id: run_id}} =
          Pipeline.create_run(%{task_id: task_id, role_id: lead.id, status: :running, started_at: DateTime.utc_now()})

        Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")
        send(test_pid, {:started_mid_close, run_id})
        Req.Test.json(conn, %{"number" => 212, "state" => "closed"})
    end)

    assert {:ok, %Task{id: ^task_id, stage: :plan}} = Pipeline.return_to_plan(scope, task)

    assert_receive {:started_mid_close, run_id}
    assert_receive {:run_changed, ^run_id}
  end

  test "a task started without approval goes back the same way", %{scope: scope, task: task, first_id: first_id} do
    Repo.update_all(from(r in Round, where: r.id == ^first_id), set: [approved_at: nil])
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    assert {:ok, %Task{stage: :plan}} = Pipeline.return_to_plan(scope, task)
    assert %Round{plan: @plan, approved_at: nil} = Repo.get!(Round, first_id)
  end

  describe "a task it refuses" do
    test "a task at Plan, whose branch is kept", %{scope: scope, task: task} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :plan})
      reject(Git, :delete_remote_branch, 2)

      assert {:error, :not_discardable} = Pipeline.return_to_plan(scope, task)
    end

    test "a task whose first round holds no plan", %{scope: scope, task: task, first_id: first_id} do
      Repo.update_all(from(r in Round, where: r.id == ^first_id), set: [plan: nil])

      assert {:error, :not_discardable} = Pipeline.return_to_plan(scope, task)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "a cleaned-up task", %{scope: scope, task: task} do
      {:ok, cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})

      assert {:error, :not_discardable} = Pipeline.return_to_plan(scope, cleaned)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "a merged task", %{scope: scope, task: task} do
      {:ok, merged} = Pipeline.update_task(task, %{stage: :finalize, merged_at: DateTime.utc_now()})

      assert {:error, :not_discardable} = Pipeline.return_to_plan(scope, merged)
      assert %Task{stage: :finalize} = Repo.reload!(task)
    end

    test "a child of a split", %{scope: scope, task: task, issue: issue} do
      parent_issue =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: issue.project_id,
          external_id: "lin_return_parent",
          identifier: "RTP-2",
          title: "Split",
          state: :in_progress
        })
        |> Repo.insert!()
        |> Repo.preload(:project)

      {:ok, %Task{id: parent_id}} = Pipeline.create_task(parent_issue, :split)
      child = task |> Ecto.Changeset.change(parent_task_id: parent_id) |> Repo.update!()

      assert {:error, :not_discardable} = Pipeline.return_to_plan(scope, child)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "a task already deleted", %{scope: scope, task: task} do
      Repo.delete!(task)

      assert {:error, :not_discardable} = Pipeline.return_to_plan(scope, task)
    end
  end
end
