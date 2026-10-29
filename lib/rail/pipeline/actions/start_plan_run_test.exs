defmodule Rail.Pipeline.Actions.StartPlanRunTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Ecto.Query

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.PlanCommentCapture
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  # Its own project, because starting a run adds a worktree to its clone.
  # The smallest plan the structure allows: one decision, one card and one criterion, and no data changes.
  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  ### Decisions

  - Decision: one module changes.

  ### Changes

  #### `lib/rail.ex`

  Extends the module.

  ### Acceptance criteria

  - 1: `lib/rail.ex`

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup %{project: %{linear_workspace_id: workspace_id}} do
    scope = system_scope()
    clone_path = Path.join(System.tmp_dir!(), "rail_start_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(clone_path) end)
    Req.Test.stub(Rail.GitHub.Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Start Plan Project",
        github_repo: "org/start-plan",
        github_installation_id: 7002,
        key: "SPL",
        default_branch: "main",
        clone_path: clone_path,
        linear_state_ids: %{"triage" => "st_triage", "in_progress" => "st_in_progress"},
        linear_workspace_id: workspace_id
      })

    roles =
      for {stage, model} <- [
            plan: "claude-opus-5-5"
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

    # Git is only ever asked through Rail.Git, so a worktree is a plain directory where the task says it goes, on the
    # commit whose sha is all a's, and the repo has no prompts of its own.
    stub(Git, :get_or_create_worktree, fn %Project{clone_path: ^clone_path}, %Task{worktree_path: path} ->
      File.mkdir_p!(path)
      {:ok, path}
    end)

    stub(Git, :branch_fingerprint, fn _path ->
      %{head_sha: String.duplicate("a", 40), dirty_digest: String.duplicate("0", 64)}
    end)

    stub(Git, :read_default_branch_file, fn %Project{clone_path: ^clone_path}, path ->
      {:error, "fatal: path '#{path}' does not exist in 'refs/remotes/origin/main'"}
    end)

    %{project: project, roles: roles, issue: issue}
  end

  test "creates the task at Plan, queues the Linear advance and spawns one process that has its plan checked", %{
    roles: %{plan: %Role{id: role_id}},
    issue: %Issue{id: issue_id} = issue
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    stub(RailWeb.Endpoint, :url, fn -> "https://rail.example.com" end)
    kit = "http://localhost:#{RailWeb.Endpoint.config(:http)[:port]}/design-kit"

    Repo.insert!(%Comment{
      issue_id: issue_id,
      external_id: "lin_comment_start_plan",
      author_name: "Ana",
      body: "It only happens on Sysco bills."
    })

    expect(Tools, :start_os_process, fn %Run{role_id: ^role_id, status: :running} = run, argv ->
      assert ["-p", prompt, "--model", "claude-opus-5-5", "--effort", "high" | _flags] = argv
      assert prompt =~ "You run Rail's Plan step"
      assert prompt =~ "You write all three yourself, and save them with Rail's tools."
      assert prompt =~ "1. The ticket first. Save it with `save_plan`"
      assert prompt =~ "three options, each saved with `save_design_option`"
      assert prompt =~ "skip them and say so in one line"
      assert prompt =~ "Never plan for all three."
      assert prompt =~ "which one you recommend and why"
      assert prompt =~ "4. Have the plan checked before you end any turn that saved it"
      assert prompt =~ "Start one subagent on a clean context to read it against the code."
      assert prompt =~ "an acceptance criterion no step delivers"
      assert prompt =~ "One check a turn: what it revised is checked when the next turn saves the plan."
      assert prompt =~ "A fix the plan check brings is the one change a line nobody commented on can take."
      assert prompt =~ "A part you leave out of a save stays as the last save left it"
      assert prompt =~ "carry it everywhere it reaches before your turn ends"
      assert prompt =~ ~s(A pick arrives as a message that says only "I picked <title> \(<key>\).")
      assert prompt =~ "One round per turn."
      assert prompt =~ "Nothing is saved yet."
      assert prompt =~ "title: Attachments follow their source document"
      assert prompt =~ ~s(<comment author="Ana")
      assert prompt =~ ~s(<script src="#{kit}/tailwind.js"></script>)
      assert prompt =~ ~s(<link rel="stylesheet" href="#{kit}/phosphor.css">)

      refute "--agents" in argv
      refute prompt =~ "may come from a CDN"
      refute prompt =~ "https://rail.example.com/design-kit"

      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{task_id: task_id, run: %Run{role_id: ^role_id}}} = Pipeline.start_plan_run(issue)

    assert %Task{stage: :plan, worktree_path: worktree_path, scratch_path: scratch_path} = Repo.get!(Task, task_id)
    assert File.dir?(worktree_path)
    assert File.dir?(Path.join(scratch_path, "design"))
    assert [%Run{role_id: ^role_id}] = Repo.all(from r in Run, where: r.task_id == ^task_id)
    assert_enqueued(worker: AdvanceTrackerState, args: %{issue_id: issue_id})
    assert_received {:pipeline_changed, ^task_id}
  end

  test "a worktree that cannot be made leaves no task and broadcasts nothing", %{issue: issue} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    test_pid = self()

    # The task is rolled back, so its id is only known from the attempt at its worktree.
    expect(Git, :get_or_create_worktree, fn _project, task ->
      send(test_pid, {:worktree_for, task.id})

      {:error,
       "Failed to create worktree at #{task.worktree_path} (git worktree add exited 128): fatal: not a git repository"}
    end)

    assert {:error, {:worktree_failed, _reason}} = Pipeline.start_plan_run(issue)

    assert_received {:worktree_for, task_id}
    refute_received {:pipeline_changed, ^task_id}
    refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
    refute Repo.exists?(Run)
    refute_enqueued(worker: AdvanceTrackerState)
  end

  test "given a run it spawns that run, its brief carrying what is already saved", %{
    roles: %{plan: role},
    issue: issue
  } do
    {:ok, task} = Pipeline.create_task(Repo.preload(issue, :project), :plan)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    worktree_path = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree_path)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})

    {:ok, _ticket} = Pipeline.save_plan(task, %{title: "Attachments follow", description: "Body."})
    design = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design)

    for key <- ["rows", "panel"] do
      File.write!(Path.join(design, "#{key}.html"), "<h1>#{key}</h1>")
      File.write!(Path.join(design, "#{key}.png"), "png")
      {:ok, _option} = Pipeline.save_design_option(task, %{key: key, title: String.capitalize(key), summary: "S."})
    end

    File.write!(Path.join(design, "picked"), "rows")
    {:ok, _plan} = Pipeline.save_plan(task, %{plan: @plan, design: "rows"})

    {:ok, %Run{id: run_id} = run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    expect(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, ["-p", prompt | _rest] = argv ->
      assert prompt =~ "- The ticket: Attachments follow"
      assert prompt =~ "- Design options: Rows (rows), Panel (panel)"
      assert prompt =~ "- The human picked rows."
      assert prompt =~ "- The plan, written for rows."
      refute prompt =~ "save_split"
      refute "--agents" in argv
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_plan_run(%{run | role: role})
  end

  test "with Product and Design off, round 1 holds the issue as its ticket and the brief hands the issue over", %{
    issue: issue
  } do
    issue = issue |> Ecto.Changeset.change(skipped_steps: [:product, :design]) |> Repo.update!()

    expect(Tools, :start_os_process, fn %Run{} = run, ["-p", prompt | _rest] ->
      assert prompt =~ "- Product is off: the issue below is the ticket"
      assert prompt =~ "- Design is off: there are no design options"
      assert prompt =~ "1. The implementation plan, saved with `save_plan` as `plan`.\n2. Have the plan checked"
      refute prompt =~ "The design options:"
      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{task_id: task_id}} = Pipeline.start_plan_run(issue)

    assert %Round{
             number: 1,
             plan: nil,
             approved_at: nil,
             ticket: %Round.Ticket{title: "Attachments follow their source document"}
           } = Pipeline.read_plan(Repo.get!(Task, task_id))
  end

  test "with Architect off the brief asks for no plan, and no round is started before the ticket", %{issue: issue} do
    issue = issue |> Ecto.Changeset.change(skipped_steps: [:architect]) |> Repo.update!()

    expect(Tools, :start_os_process, fn %Run{} = run, ["-p", prompt | _rest] ->
      assert prompt =~ "- Architect is off: there is no implementation plan."
      assert prompt =~ "- Approval needs the ticket and, when there are options, a pick."
      refute prompt =~ "Have the plan checked"
      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{task_id: task_id}} = Pipeline.start_plan_run(issue)
    assert Pipeline.read_plan(Repo.get!(Task, task_id)) == nil
  end

  test "with Design, Architect and the demo off, approval needs the ticket alone", %{issue: issue} do
    issue = issue |> Ecto.Changeset.change(skipped_steps: [:design, :architect, :demo]) |> Repo.update!()

    expect(Tools, :start_os_process, fn %Run{} = run, ["-p", prompt | _rest] ->
      assert prompt =~ "- Approval needs the ticket.\n"
      assert prompt =~ "- The demo is off: Review records none, so never pass `record_demo`."
      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_plan_run(issue)
  end

  test "the brief carries the rules people set for Plan, and not another role's", %{project: project, issue: issue} do
    stub_vertex(%{"source document" => vector([1.0])})
    learning(project, %{rule: "Copy says task, never ticket", kind: :product, roles: [:plan]}, embedding: [1.0])
    learning(project, %{rule: "Engineers only", kind: :convention, roles: [:engineer]}, embedding: [1.0])

    expect(Tools, :start_os_process, fn %Run{} = run, ["-p", prompt | _rest] ->
      assert prompt =~ "- Product: Copy says task, never ticket"
      refute prompt =~ "Engineers only"
      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_plan_run(issue)
  end

  test "a rule learned from a design comment on a large element carries no more than the start of its HTML", %{
    project: project,
    issue: issue
  } do
    stub_vertex(%{"source document" => vector([1.0])})
    html = "<section>" <> String.duplicate("a", 2_000) <> "NEVER_IN_A_BRIEF" <> "</section>"

    {:ok, [rule]} =
      Learnings.record_corrections(learnings_task(project, "SPR-9"), [
        %PlanComment{
          id: "pcm_spr_1",
          target: :design,
          option_key: "lanes",
          selector: "#lanes",
          element_text: "Lanes",
          element_tag: "section",
          body: "Fewer lanes",
          capture: %PlanCommentCapture{html: html, width: 1600, height: 900}
        }
      ])

    Repo.update_all(from(l in Learning, where: l.id == ^rule.id),
      set: [embedding: Pgvector.new(vector([1.0])), embedding_model: "gemini-embedding-001"]
    )

    expect(Tools, :start_os_process, fn %Run{} = run, ["-p", prompt | _rest] ->
      assert prompt =~ "Design (provisional, from a recent correction): Fewer lanes"
      assert prompt =~ String.slice(html, 0, 2_000)
      refute prompt =~ "NEVER_IN_A_BRIEF"
      {:ok, %OsProcess{task_id: run.task_id, run: run, task: run.task}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_plan_run(issue)
  end
end
