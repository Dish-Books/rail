defmodule Rail.Pipeline.Actions.ReturnToPlanTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
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
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Users

  @plan "## Implementation plan\n\nFilter by vendor."

  # A project of its own, because the branch is pushed to and deleted from a real `origin`.
  setup %{project: %{id: seeded_id, linear_workspace_id: workspace_id}} do
    origin = Path.join(System.tmp_dir!(), "rail_return_origin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf(origin) end)
    git!(origin, ["init", "--bare", "--quiet", "-b", "main"])

    clone = create_temp_git_repo(prefix: "rail_return_clone")
    git!(clone, ["remote", "add", "origin", origin])
    git!(clone, ["push", "--quiet", "origin", "main"])

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_return"}]}}})
    end)

    # Keyed and named per test, since a key, repo or login two open sandboxes both insert waits on the other's.
    n = System.unique_integer([:positive])
    repo = "org/return-#{n}"
    pull_path = "/repos/#{repo}/pulls/212"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Return Project #{n}",
        github_repo: repo,
        github_installation_id: 8708,
        key: "rtp#{n}",
        default_branch: "main",
        clone_path: clone,
        linear_workspace_id: workspace_id
      })

    # The Planner starts on the project's own roles, which a new project has none of.
    {:ok, _roles} = Roles.copy_roles(system_scope(), project.id, seeded_id)

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
    git!(clone, ["worktree", "add", "--quiet", "-b", task.worktree_name, task.worktree_path])
    File.write!(Path.join(task.worktree_path, "work.ex"), "work\n")
    git!(task.worktree_path, ["add", "."])
    git!(task.worktree_path, ["commit", "--quiet", "-m", "Work"])
    git!(task.worktree_path, ["push", "--quiet", "origin", task.worktree_name])
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
      %{method: "POST", request_path: "/app/installations/8708/access_tokens"} = conn ->
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
      origin: origin,
      lead: lead,
      plan_role: plan_role,
      first_id: first_id
    }
  end

  test "erases the work, keeps the ticket, design and plan, and starts the Planner on a new conversation", %{
    scope: scope,
    task: task,
    issue: %Issue{id: issue_id} = issue,
    origin: origin,
    lead: lead,
    plan_role: %{id: plan_role_id} = plan_role,
    reader: reader,
    reader_scope: reader_scope,
    first_id: first_id
  } do
    {:ok, %Task{id: task_id} = task} = Pipeline.update_task(task, %{pr_number: 212})
    now = DateTime.utc_now()

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
    refute File.exists?(Path.join(task.worktree_path, "work.ex"))
    refute git!(task.worktree_path, ["log", "--format=%s"]) =~ "Work"
    assert "" = git!(origin, ["branch", "--list", task.worktree_name])

    assert %Issue{state: :in_progress, state_name: nil} = Repo.get!(Issue, issue_id)
    assert_enqueued(worker: SyncIssue, args: %{issue_id: issue_id, fields: ["state", "state_name"]})
  end

  test "a task started without approval goes back the same way", %{scope: scope, task: task, first_id: first_id} do
    Repo.update_all(from(r in Round, where: r.id == ^first_id), set: [approved_at: nil])
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    assert {:ok, %Task{stage: :plan}} = Pipeline.return_to_plan(scope, task)
    assert %Round{plan: @plan, approved_at: nil} = Repo.get!(Round, first_id)
  end

  test "a new push after Back to Plan goes up cleanly on the same branch name", %{scope: scope, task: task} do
    assert {:ok, %Task{} = planning} = Pipeline.return_to_plan(scope, task)

    File.write!(Path.join(planning.worktree_path, "fresh.ex"), "fresh\n")
    git!(planning.worktree_path, ["add", "."])
    git!(planning.worktree_path, ["commit", "--quiet", "-m", "Fresh start"])

    assert :ok = Git.check_push(planning)
  end

  describe "a task it refuses" do
    test "a task at Plan", %{scope: scope, task: task, origin: origin} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :plan})

      assert {:error, :not_discardable} = Pipeline.return_to_plan(scope, task)
      assert git!(origin, ["branch", "--list", task.worktree_name]) =~ task.worktree_name
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
