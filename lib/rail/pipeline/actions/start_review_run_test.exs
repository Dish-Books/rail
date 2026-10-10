defmodule Rail.Pipeline.Actions.StartReviewRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

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

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :review)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)
    # Between rounds, where the human rules.
    {:ok, run} = Pipeline.update_run(run, %{status: :finished})

    %{task: task, run: %{run | role: role}}
  end

  test "spawns the lead on its own model with the code reviewer, explorer, engineer and demo recorder", %{
    task: task,
    run: run
  } do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", _prompt, "--model", "claude-opus-5-5" | _rest] = argv
      [json] = for ["--agents", json] <- Enum.chunk_every(argv, 2, 1), do: json

      assert %{
               "code-reviewer" => %{"model" => "claude-opus-5-5"},
               "explorer" => %{"model" => "claude-opus-5-5"},
               "engineer" => %{"model" => "claude-opus-5-5"},
               "demo-recorder" => %{"model" => "claude-opus-5-5"}
             } = Jason.decode!(json)

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_review_run(run)
    assert File.dir?(Path.join([task.scratch_path, "qa", "evidence"]))
    assert File.dir?(Path.join(task.scratch_path, "demo"))
  end

  test "the brief lists the findings already on the task with their rounds, rulings, places and notes", %{
    task: task,
    run: run
  } do
    {:ok, finding} =
      Pipeline.save_finding(task, %{
        key: "send-twice",
        kind: :screen,
        raised_by: :explorer,
        title: "Send stays enabled while a round is on its way",
        problem: "A second click sends the same comments twice.",
        screen: "Engineer tab, Diff toolbar",
        steps: ["Click Send twice"],
        fix: "Disable Send until the server answers.",
        why: "Two runs for one round.",
        rule: "A round is sent once, however many times Send is pressed.",
        severity: :major,
        recommendation: :fix,
        places: [%{screen: "Engineer tab, Diff toolbar", label: "Send button"}, %{file: "lib/a.ex", line: 22}],
        evidence: [%{name: "count", kind: :note, text: "2 deliveries"}],
        note: "Seen by explorer-1."
      })

    {:ok, %{round: 1}} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), finding, :fix)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Fix round 1"])
    {:ok, %{round: 2}} = Pipeline.save_review(task)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Fix round 2"])
    {:ok, _carried} = Pipeline.save_finding(task, %{key: "send-twice", status: "not_fixed", note: "Still twice."})

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~
               "- `send-twice` [carried into round 3, major screen, human ruled: Fix, status: not_fixed] " <>
                 "Send stays enabled while a round is on its way (Engineer tab, Diff toolbar)"

      assert prompt =~ "  Rule: A round is sent once, however many times Send is pressed."
      assert prompt =~ "  Place 1: Engineer tab, Diff toolbar, Send button"
      assert prompt =~ "  Place 2: lib/a.ex:22"
      assert prompt =~ ~r/  Round 1, raised on [0-9a-f]{7}: Seen by explorer-1\./
      assert prompt =~ "  Round 1, ruled Fix"
      assert prompt =~ ~r/  Round 3, not_fixed on [0-9a-f]{7}: Still twice\./
      assert prompt =~ ~r/  Round 3, carried on [0-9a-f]{7}/

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_review_run(run)
  end

  # The engineer commits and keeps the branch up to date; Rail only pushes what a turn leaves committed.
  test "briefs the lead that its engineer commits, Rail pushes, and the branch is checked against main each turn", %{
    task: %Task{worktree_path: worktree_path},
    run: run
  } do
    test_pid = self()

    expect(Rail.Pipeline.Utils.PrepareTurn, :prepare_turn, fn %Run{task: %Task{worktree_path: ^worktree_path}} ->
      send(test_pid, :prepared)
      :ok
    end)

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert_received :prepared
      assert prompt =~ "the engineer makes and commits every change"
      assert prompt =~ "ending each commit message with the line `Ticket: SRV-1`"
      assert prompt =~ "Nobody pushes: a turn that ends with commits the remote does not have yet hands them to Rail"
      assert prompt =~ "check the branch against `origin/main`, which Rail fetched as the turn started"
      assert prompt =~ "have the engineer bring it up to date by merge or rebase"
      assert prompt =~ "Save each Fix finding with `save_finding`, `status` fixed"
      assert prompt =~ "A turn that committed while a Fix finding is not saved fixed is held"
      refute prompt =~ "`commit`"
      refute prompt =~ "request_merge"
      refute prompt =~ "merge_follow_up"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_review_run(run)
  end

  test "a fixed finding, one ruled Don't fix and one from before rules read as such, and the plan is the specification",
       %{
         task: task,
         run: run
       } do
    attrs = %{
      kind: :code,
      raised_by: :code_reviewer,
      problem: "It crashes.",
      file: "lib/a.ex",
      line: 3,
      fix: "Guard it.",
      why: "It crashes.",
      rule: "Every caller handles nil.",
      severity: :minor,
      recommendation: :skip,
      places: [%{file: "lib/a.ex", line: 3}],
      evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
    }

    {:ok, dismissed} = Pipeline.save_finding(task, Map.merge(attrs, %{key: "left-alone", title: "Left alone"}))
    {:ok, _dismissed} = Pipeline.decide_finding(system_scope(), dismissed, :skip)

    {:ok, _fixed} =
      Pipeline.save_finding(task, Map.merge(attrs, %{key: "already-fixed", title: "Already fixed"}))

    {:ok, _fixed} = Pipeline.save_finding(task, %{key: "already-fixed", status: "fixed"})

    # Findings carried over from the old review table have no rule.
    Repo.insert!(%Finding{
      task_id: task.id,
      key: "migrated",
      kind: :code,
      raised_by: :code_reviewer,
      round: 1,
      title: "Migrated",
      file: "lib/b.ex",
      line: 1,
      severity: :nit,
      recommendation: :skip
    })

    Repo.insert!(%ImplementationPlan{
      task_id: task.id,
      content: "## Implementation plan\n\nFilter by vendor.",
      captured_at: DateTime.utc_now()
    })

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt =~
               "- `left-alone` [round 1, minor code, human ruled: Don't fix, status: open] Left alone (lib/a.ex:3)"

      assert prompt =~ "- `already-fixed` [round 1, minor code, human ruled: not yet, status: fixed] Already fixed"
      assert prompt =~ ~r/human ruled: not yet, status: open\] Migrated \(lib\/b\.ex:1\)\n(?!  Rule)/
      assert prompt =~ "Filter by vendor."

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_review_run(run)
  end

  test "an answer turn sends only the answer", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      assert prompt == "Start fix round 1.\n\nContinue from where you stopped.\n"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} =
             Pipeline.start_review_run(%{run | pending_answer: "Start fix round 1.", conversation_id: "sess_srv"})
  end

  describe "the checklist" do
    test "carries the rules found per changed file, with ids, for the lead to hand on, and names the id field", %{
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
        assert prompt =~ "- `#{rule.id}` Convention: Tests use the factory Applies to `test/**`."
        assert prompt =~ "- `#{calibration.id}` Calibration: Don't flag a missing @doc"
        assert prompt =~ "give that rule's id as `checklist_rule`"
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
