defmodule Rail.Pipeline.Actions.StartPlanRunTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceLinearState
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  # Its own project, because starting a run adds a worktree to a real clone.
  # The smallest plan the structure allows: no diagrams, so Approach says why, and no Program design.
  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  No diagrams: one module changes.

  ### File-level changes

  - `lib/rail.ex`: extends the module.

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup %{project: %{linear_workspace_id: workspace_id}} do
    scope = system_scope()
    clone_path = create_temp_git_repo()
    git!(clone_path, ["remote", "add", "origin", create_temp_git_repo(prefix: "rail_start_plan_remote")])
    Req.Test.stub(Rail.GitHub.Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Plan Project",
        github_repo: "org/start-plan",
        github_installation_id: 7002,
        linear_team_key: "SPL",
        default_branch: "main",
        clone_path: clone_path,
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"},
        linear_workspace_id: workspace_id
      })

    roles =
      for {stage, model} <- [
            plan: "claude-opus-5-5",
            product: "claude-sonnet-5-5",
            design: "claude-opus-5-5",
            architect: "claude-fable-5-1"
          ],
          into: %{} do
        {:ok, role} =
          Roles.create_role(scope, project, %{
            cli: :claude,
            stage: stage,
            name: "#{stage} role",
            model: model,
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_plan_1",
              "identifier" => "SPL-1",
              "title" => "Attachments follow their source document"
            }
          }
        }
      })
    end)

    {:ok, issue} =
      Issues.create_issue(system_scope(), project, %{description: "Attachments follow their source document"})

    %{project: project, roles: roles, issue: issue}
  end

  test "creates the task at Plan, queues the Linear advance and spawns one process with the three subagents", %{
    roles: %{plan: %Role{id: role_id}},
    issue: %Issue{id: issue_id} = issue
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    Repo.insert!(%Comment{
      issue_id: issue_id,
      external_id: "lin_comment_start_plan",
      author_name: "Ana",
      body: "It only happens on Sysco bills."
    })

    expect(Tools, :start_os_process, fn %Run{role_id: ^role_id, status: :running} = run, argv ->
      assert ["-p", prompt, "--model", "claude-opus-5-5", "--effort", "high" | _flags] = argv
      assert prompt =~ "You lead Rail's Plan step"
      assert prompt =~ "Product, Designer and Architect are your subagents"
      assert prompt =~ "1. Product first."
      assert prompt =~ "hand it to Designer and Architect at once rather than one after the other"
      assert prompt =~ "Architect does not wait for the design"
      assert prompt =~ "include every rule from the rules section of this brief that bears on its output, word for word"
      assert prompt =~ "skip Designer and say so in one line"
      assert prompt =~ "which one you recommend and why"
      assert prompt =~ "then to each other subagent whose output it affects"
      assert prompt =~ ~s(A pick arrives as a message that says only "I picked <title> \(<key>\).")
      assert prompt =~ "One round per turn."
      assert prompt =~ "Nothing is saved yet."
      assert prompt =~ "title: Attachments follow their source document"
      assert prompt =~ ~s(<comment author="Ana")

      [json] = for ["--agents", json] <- Enum.chunk_every(argv, 2, 1), do: json

      assert %{
               "product" => %{"model" => "claude-sonnet-5-5", "prompt" => "You are the product agent." <> _product},
               "designer" => %{"model" => "claude-opus-5-5", "prompt" => "You are the design agent." <> _design},
               "architect" => %{"model" => "claude-fable-5-1", "prompt" => "You are the architect agent." <> _architect}
             } = Jason.decode!(json)

      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{task_id: task_id, run: %Run{role_id: ^role_id}}} = Pipeline.start_plan_run(issue)

    assert %Task{stage: :plan, worktree_path: worktree_path, scratch_path: scratch_path} = Repo.get!(Task, task_id)
    assert File.dir?(worktree_path)
    assert File.dir?(Path.join(scratch_path, "design"))
    assert [%Run{role_id: ^role_id}] = Repo.all(from r in Run, where: r.task_id == ^task_id)
    assert_enqueued(worker: AdvanceLinearState, args: %{issue_id: issue_id})
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a worktree that cannot be made leaves no task and broadcasts nothing", %{project: project, issue: issue} do
    File.rm_rf!(Path.join(project.clone_path, ".git"))
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    test_pid = self()

    # The task is rolled back, so its id is only known from the attempt at its worktree.
    stub(Git, :get_or_create_worktree, fn project, task ->
      send(test_pid, {:worktree_for, task.id})
      call_original(Git, :get_or_create_worktree, [project, task])
    end)

    assert {:error, {:worktree_failed, _reason}} = Pipeline.start_plan_run(issue)

    assert_received {:worktree_for, task_id}
    refute_received {:pipeline_changed, ^task_id}
    refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
    refute Repo.exists?(Run)
    refute_enqueued(worker: AdvanceLinearState)
  end

  test "given a run it spawns that run, its brief carrying what is already saved", %{
    roles: %{plan: role},
    issue: issue
  } do
    {:ok, task} = Pipeline.create_task(Repo.preload(issue, :project), :plan)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, _ticket} = Pipeline.save_ticket(task, %{title: "Attachments follow", description: "Body."})
    design = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design)

    for key <- ["rows", "panel"] do
      File.write!(Path.join(design, "#{key}.html"), "<h1>#{key}</h1>")
      File.write!(Path.join(design, "#{key}.png"), "png")
      {:ok, _option} = Pipeline.save_design_option(task, %{key: key, title: String.capitalize(key), summary: "S."})
    end

    File.write!(Path.join(design, "picked"), "rows")
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "rows"})

    {:ok, _split} =
      Pipeline.save_split(task, %{
        "children" => [
          %{"title" => "Deploys", "ticket" => "T1.", "plan" => "## Implementation plan\n\nOne."},
          %{"title" => "QA on them", "ticket" => "T2.", "plan" => "## Implementation plan\n\nTwo.", "builds_on" => [1]}
        ]
      })

    {:ok, %Run{id: run_id} = run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    expect(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, ["-p", prompt | _rest] = argv ->
      assert prompt =~ "- The ticket: Attachments follow"
      assert prompt =~ "- Design options: Rows (rows), Panel (panel)"
      assert prompt =~ "- The human picked rows."
      assert prompt =~ "- The plan, written for rows."
      assert prompt =~ "- A split into 2: 1. Deploys; 2. QA on them."
      assert prompt =~ "have Architect decide where it splits and save it with `save_split`"
      assert "--agents" in argv
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_plan_run(%{run | role: role})
  end

  test "the brief carries the rules people set for product, design and architect", %{project: project, issue: issue} do
    stub_vertex(%{"source document" => vector([1.0])})
    learning(project, %{rule: "Copy says task, never ticket", kind: :product, roles: [:design]}, embedding: [1.0])
    learning(project, %{rule: "Engineers only", kind: :convention, roles: [:engineer]}, embedding: [1.0])

    expect(Tools, :start_os_process, fn %Run{} = run, ["-p", prompt | _rest] ->
      assert prompt =~ "- Product: Copy says task, never ticket"
      refute prompt =~ "Engineers only"
      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_plan_run(issue)
  end
end
