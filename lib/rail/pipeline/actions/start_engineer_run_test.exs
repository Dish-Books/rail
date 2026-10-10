defmodule Rail.Pipeline.Actions.StartEngineerRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Learnings.Schemas.LearningRetrieval
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

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

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_engineer_1",
              "identifier" => "SEN-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{project: project, task: task, run: run}
  end

  test "briefs the engineer on the plan it builds and how its commits are handed over", %{
    task: %Task{worktree_path: worktree_path} = task,
    run: run
  } do
    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content:
        ~s{### Approach\nExtend the invoices module.\n\n```mermaid\nflowchart LR\n  A["InvoicesLive"] --> B["Invoices"]\n```\n\n```elixir\ndef list_invoices(scope, filters)\n```},
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    commits_dir = Path.join(task.scratch_path, "commits")
    test_pid = self()

    # Each turn starts on a fresh default branch, committing as the ticket's owner, and opens on whether the
    # branch is behind it.
    expect(Rail.Pipeline.Utils.PrepareTurn, :prepare_turn, fn %Run{task: %Task{worktree_path: ^worktree_path}} ->
      send(test_pid, :prepared)
      "The branch is behind origin/main.\n\n"
    end)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert_received :prepared

      assert ["-p", "The branch is behind origin/main.\n\nBuild the approved plan below." <> _brief = prompt | _rest] =
               argv

      assert prompt =~ "Build the approved plan below."
      assert prompt =~ "Extend the invoices module."
      assert prompt =~ ~s(```mermaid\nflowchart LR\n  A["InvoicesLive"] --> B["Invoices"]\n```)
      assert prompt =~ "```elixir\ndef list_invoices(scope, filters)\n```"
      assert prompt =~ "A turn that ends with commits the remote does not have yet hands them over"
      assert prompt =~ "Work you leave uncommitted is not sent on"
      assert prompt =~ "Your last message is what the human reads, not the commit body"
      assert prompt =~ "End every commit message with the line `Ticket: SEN-1`."
      assert prompt =~ "check your branch against `origin/main`, which Rail fetched as the turn started"
      assert prompt =~ "bring it up to date by merge or rebase"
      refute prompt =~ "`commit`"
      refute prompt =~ "request_merge"
      refute prompt =~ "<<'MSG'"
      refute prompt =~ commits_dir
      assert prompt =~ "Git is yours to use, commits included, except for what Rail does for you: no push"
      assert prompt =~ "Your worktree is #{task.worktree_path}"
      assert prompt =~ "The branch #{task.worktree_name} is already checked out"
      assert prompt =~ "its base is main on remote `origin`"
      assert prompt =~ "Ask everything at once."
      assert prompt =~ "Run every command in the foreground and wait for it"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
    refute File.exists?(commits_dir)
  end

  # Product can approve straight past design and architect, which leaves no plan.
  test "says the ticket is the whole specification when there is no plan", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "There is no implementation plan for this ticket"
      assert prompt =~ "Filter invoices by vendor."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  test "carries the design page the human approved, not just a path to it", %{task: task, run: run} do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "cards", "title": "Cards"}, {"key": "table", "title": "Table"}]})
    )

    File.write!(Path.join(design_dir, "cards.html"), "<h1>Invoices</h1>")
    File.write!(Path.join(design_dir, "table.html"), "<table>Rejected</table>")
    File.write!(Path.join(design_dir, "picked"), "cards")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ ~s(The human approved the design "Cards")
      assert prompt =~ ~s(<design title="Cards">\n<h1>Invoices</h1>\n</design>)
      assert prompt =~ "#{design_dir}/cards.html"
      refute prompt =~ "Rejected"

      # The design is read against the ticket, so it comes before it.
      assert :binary.match(prompt, "</design>") < :binary.match(prompt, "The ticket it was planned from")

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  test "a plan and a picked option revised after approval are what the next Engineer brief carries", %{
    task: task,
    run: run
  } do
    Repo.insert!(%ImplementationPlan{
      task_id: task.id,
      content: "## Implementation plan\n\nAs approved.",
      captured_at: DateTime.utc_now()
    })

    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)
    File.write!(Path.join(design_dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))
    File.write!(Path.join(design_dir, "cards.html"), "<h1>As approved</h1>")
    File.write!(Path.join(design_dir, "picked"), "cards")

    {:ok, _plan} =
      Pipeline.save_plan(task, %{plan: String.replace(@plan, "Extend the module.", "Revised for the comments.")})

    File.write!(Path.join(design_dir, "cards.html"), "<h1>Revised for the comments</h1>")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Revised for the comments."
      assert prompt =~ "<h1>Revised for the comments</h1>"
      refute prompt =~ "As approved"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  # Product can approve straight past design, which leaves nothing on disk to read.
  test "says nothing about a design when there is none", %{task: task, run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "approved the design"
      refute prompt =~ Path.join(task.scratch_path, "design")

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  # A design nobody picked is not the approved one, so it is not what gets built.
  test "says nothing about options the human never picked between", %{task: task, run: run} do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(Path.join(design_dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))
    File.write!(Path.join(design_dir, "cards.html"), "<h1>Invoices</h1>")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "approved the design"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  # An option whose page was never written has nothing to hand over.
  test "says nothing about a design whose page is missing", %{task: task, run: run} do
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)

    File.write!(Path.join(design_dir, "manifest.json"), ~s({"options": [{"key": "cards", "title": "Cards"}]}))
    File.write!(Path.join(design_dir, "picked"), "cards")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "approved the design"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  test "carries every comment on the issue", %{task: task, run: run} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "lin_comment_1",
              "body" => "Use the existing filter helper.",
              "createdAt" => "2026-09-14T10:00:00.000Z",
              "issue" => %{"id" => "lin_start_engineer_1"}
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.get_issue(task.issue_id)
    {:ok, _comment} = Issues.comment(system_scope(), issue, %{body: "Use the existing filter helper."})

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Use the existing filter helper."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_engineer_run(run)
  end

  test "tells the engineer CI runs on its commit, and that failures come back to it", %{project: project, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Rail runs `mise run ci` on them before anything else sees them"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_engineer_run(run)
  end

  describe "what the project has learned" do
    test "the brief carries the rules retrieved with the ticket and the plan, and the run's retrievals are logged", %{
      project: project,
      task: task,
      run: run
    } do
      stub_vertex(%{"Filter invoices" => vector([1.0])})

      %ImplementationPlan{}
      |> ImplementationPlan.changeset(%{
        task_id: task.id,
        content: "Extend the invoices module.",
        captured_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      rule =
        learning(project, %{rule: "Filters live in the URL", why: "So a view can be linked", kind: :convention},
          embedding: [1.0]
        )

      pinned = learning(project, %{rule: "Never run git", kind: :environment, pinned: true})

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "What this project has learned."
        assert prompt =~ "- Convention: Filters live in the URL\n  Why: So a view can be linked"
        assert prompt =~ "- Environment: Never run git"
        assert prompt =~ "`knowledge_search`"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %OsProcess{}} = Pipeline.start_engineer_run(run)
      assert_received {:embedded, "Invoice filters\n\nFilter invoices by vendor.", "RETRIEVAL_QUERY"}
      assert_received {:embedded, "Extend the invoices module.", "RETRIEVAL_QUERY"}

      assert Enum.sort([rule.id, pinned.id]) ==
               Enum.sort(Repo.all(from r in LearningRetrieval, where: r.run_id == ^run.id, select: r.learning_id))
    end

    test "an answer turn is given no rules, since only the answer is sent", %{project: project, run: run} do
      learning(project, %{rule: "Never run git", kind: :environment, pinned: true})

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        refute prompt =~ "Never run git."
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %OsProcess{}} = Pipeline.start_engineer_run(%{run | pending_answer: "Blue."})
      assert [] = Repo.all(from r in LearningRetrieval, where: r.run_id == ^run.id)
    end
  end
end
