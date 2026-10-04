defmodule Rail.Pipeline.Actions.StartReviewRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_review_1",
              "identifier" => "SRV-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :review)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{task: task, run: run}
  end

  test "briefs the reviewer on the change and the one report file it writes", %{task: task, run: run} do
    reviews_dir = Path.join(task.scratch_path, "reviews")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Review the change described below."
      assert prompt =~ "You are reading it, not changing it"
      assert prompt =~ "git diff origin/main...HEAD"
      assert prompt =~ "The branch #{task.worktree_name}" or prompt =~ task.worktree_name
      assert prompt =~ "cat > #{reviews_dir}/SRV-1.json <<'JSON'"
      assert prompt =~ "Ask everything at once."
      assert prompt =~ "Filter invoices by vendor."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
    assert File.dir?(reviews_dir)
  end

  test "keeps severity and recommendation apart, so a nit can still be worth fixing", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "They are separate axes"
      assert prompt =~ "a nit worth the thirty seconds it costs is `fix`, and a blocker is never `skip`"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  # The human rules on the reasoning and the engineer is handed the remedy, so the
  # two are separate fields and the brief has to say which is which.
  test "tells the reviewer the reasoning and the remedy have different readers", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "`detail` and `suggestion` have different readers"
      assert prompt =~ "the whole of what the engineer is handed"
      assert prompt =~ "whether this change caused the problem or merely stands next to it"
      assert prompt =~ ~s("suggestion": "the change that settles it")
      assert prompt =~ "written as though the finding will be fixed"
      assert prompt =~ "hands the engineer a decision the human has already taken"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "asks the reviewer to confirm what it reports rather than guess", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Report only what you checked."
      assert prompt =~ "open the callers, read the test, run it"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "says the ticket is the whole specification when nothing planned it", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "There is no implementation plan for this ticket"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "reads the change against the plan it was built from", %{task: task, run: run} do
    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content:
        ~s{## Implementation plan\n\nExtend the invoice filter module.\n\n```mermaid\nflowchart LR\n  A["InvoicesLive"] --> B["Invoices"]\n```\n\n```elixir\ndef list_invoices(scope, filters)\n```},
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Extend the invoice filter module."
      assert prompt =~ ~s(```mermaid\nflowchart LR\n  A["InvoicesLive"] --> B["Invoices"]\n```)
      assert prompt =~ "```elixir\ndef list_invoices(scope, filters)\n```"
      assert prompt =~ "It is the specification:"
      refute prompt =~ "There is no implementation plan"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "a first pass is not asked to verify anything", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "This change has been reviewed before"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  test "hands a later pass every finding already on the task, with what the human decided", %{
    task: task,
    run: run
  } do
    {:ok, [to_fix, dismissed]} =
      Pipeline.sync_review_findings(task, [
        %{
          key: "unhandled-nil",
          title: "Nil is not handled",
          detail: "The clause assumes a map.",
          file: "lib/rail/example.ex",
          line: 12,
          severity: :major,
          recommendation: :fix,
          status: :open
        },
        %{
          key: "naming-nit",
          title: "The variable could be named better",
          detail: nil,
          file: nil,
          line: nil,
          severity: :nit,
          recommendation: :fix,
          status: :open
        }
      ])

    {:ok, _all} =
      Pipeline.sync_review_findings(task, [
        %{key: "not-ruled-on", title: "Nobody has looked", severity: :minor, recommendation: :fix, status: :open}
      ])

    {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished})
    {:ok, _to_fix} = Pipeline.decide_review_finding(system_scope(), to_fix, :fix)
    {:ok, _skipped} = Pipeline.decide_review_finding(system_scope(), dismissed, :skip)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "This change has been reviewed before"
      assert prompt =~ "`unhandled-nil` [major, human decided: fix it, status: open] Nil is not handled"
      assert prompt =~ "(lib/rail/example.ex:12)"
      assert prompt =~ "`naming-nit` [nit, human decided: dismissed, leave it, status: open]"
      # A turn that came back before anybody read it leaves findings nobody has
      # ruled on, and the next pass is owed the truth about that rather than a
      # default.
      assert prompt =~ "`not-ruled-on` [minor, human decided: not yet decided, status: open]"
      assert prompt =~ "never argue it again"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
  end

  describe "the checklist" do
    test "carries the rules found per changed file, with ids, the calibration instruction and the rule field", %{
      project: project,
      run: run
    } do
      stub_vertex(%{"Repo.insert!" => vector([1.0])})

      stub(Rail.Git, :load_diff, fn _scope, _task, :branch ->
        {:ok,
         [
           %{
             path: "test/a_test.exs",
             rows: [
               %{kind: :hunk_header},
               %{kind: :line, line_kind: :added, text: "Repo.insert!(row)"},
               %{kind: :line, line_kind: :context, text: "end"}
             ]
           },
           %{path: "priv/logo.png", rows: [%{kind: :binary}]}
         ]}
      end)

      rule =
        learning(project, %{rule: "Tests use the factory", kind: :convention, path_glob: "test/**"}, embedding: [1.0])

      calibration = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration, pinned: true})

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "The checklist: rules this project has learned."
        assert prompt =~ "- `#{rule.id}` Convention: Tests use the factory Applies to `test/**`."
        assert prompt =~ "- `#{calibration.id}` Calibration: Don't flag a missing @doc"
        assert prompt =~ "A finding one says not to raise is still written, with that rule's id as `rule`"
        assert prompt =~ ~s("rule": null)
        assert prompt =~ "`rule` is the id of the checklist rule a finding comes from"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %OsProcess{}} = Pipeline.start_review_run(run)
      assert_received {:embedded, "test/a_test.exs\nRepo.insert!(row)", "CODE_RETRIEVAL_QUERY"}
      refute_received {:embedded, "priv/logo.png" <> _rest, _task_type}
    end

    test "a worktree that is gone gives no per-file rules", %{project: project, run: run} do
      stub(Rail.Git, :load_diff, fn _scope, _task, :branch -> {:error, :no_worktree} end)
      learning(project, %{rule: "Pinned anyway", kind: :convention, pinned: true})

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "Pinned anyway"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %OsProcess{}} = Pipeline.start_review_run(run)
    end
  end
end
