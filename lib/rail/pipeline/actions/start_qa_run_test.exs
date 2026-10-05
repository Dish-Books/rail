defmodule Rail.Pipeline.Actions.StartQaRunTest do
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

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :qa)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_start_qa_1",
              "identifier" => "SQA-1",
              "title" => "Invoice filters",
              "description" => "Filter invoices by vendor."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Filter invoices by vendor."})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{task: task, run: run}
  end

  test "briefs QA on the change, the tools it reports with and where evidence goes", %{task: task, run: run} do
    qa_dir = Path.join(task.scratch_path, "qa")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "QA the change described below by driving the running application."
      assert prompt =~ "You are testing it, not changing it"
      assert prompt =~ "git diff origin/main...HEAD"
      assert prompt =~ task.worktree_name
      assert prompt =~ "`save_finding` saves one finding, as soon as you have reproduced it"
      assert prompt =~ "`save_verdict` saves your `verdict`, `summary` and `not_checked`, and it is the last thing you do"
      refute prompt =~ "<<'JSON'"
      refute prompt =~ "#{qa_dir}/SQA-1.json"
      assert prompt =~ "A screenshot comes from `qa_shot`"
      # Reading a picture is what costs, and Rail cannot take one back out of a
      # context once it is in one.
      assert prompt =~ "read one with the Read tool when a check turns on how something looks"
      assert prompt =~ "Anything else you captured goes into #{qa_dir}/evidence"
      assert prompt =~ "Ask everything at once."
      assert prompt =~ "Filter invoices by vendor."

      # The browser and the checklist are Rail's, so the brief is where they are
      # named rather than the project's own prompt.
      assert prompt =~ "Call `browser_connect` for its address and for `driver.mjs`"
      assert prompt =~ "You name every element yourself"
      assert prompt =~ "call `qa_plan` with every check this pass will run"
      assert prompt =~ "Call `qa_check` on each one the moment you have run it"
      assert prompt =~ "each under a `group` that says what kind of check it is"
      assert prompt =~ "`summary` is one or two sentences"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{run: %Run{}}} = Pipeline.start_qa_run(run)
  end

  # A check proved by a log or a PDF is evidenced by that file, so the brief asks
  # for evidence on every row rather than a picture on every row.
  test "asks for evidence on every check, a picture where it is on screen", %{task: task, run: run} do
    qa_dir = Path.join(task.scratch_path, "qa")

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Every check gets evidence filed against it"
      assert prompt =~ "A check that asserts something on screen gets a `qa_shot` at that moment"
      assert prompt =~ "then call `qa_file` with the row's key, a caption and the path relative to #{qa_dir}"
      assert prompt =~ "A check can carry both."
      assert prompt =~ "a change with nothing on screen is proved by what it writes, not by opening the browser"
      assert prompt =~ "A file you filed with `qa_file` is cited the same way, by the name it handed back"
      refute prompt =~ "Take at least one for every check"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  # The agent writes its screenshots here, so it exists before the agent does.
  test "the evidence directory is made before QA starts", %{task: task, run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
    assert File.dir?(Path.join([task.scratch_path, "qa", "evidence"]))
  end

  test "says the verdict is a judgement rather than a tally", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "`verdict` is `pass`, `concerns` or `fail`"
      assert prompt =~ "your judgement rather than a tally"
      assert prompt =~ "it gates nothing"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "asks for a key that survives the next pass and a check anyone can re-run", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "it must stay the same for the same defect across passes"
      assert prompt =~ "a finding nobody can re-run is a finding nobody can close"
      assert prompt =~ "`caused_by_change` is `false` for something that was already broken"
      assert prompt =~ "never absolute and never climbing out with `..`"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  # A finding shows only its own evidence, so a reader who opens it sees the
  # defect rather than every picture filed against the row it came from.
  test "says a finding without usable evidence sends the whole report back", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "Every finding must carry at least one piece of usable evidence"
      assert prompt =~ "is refused at that call, so file the evidence first and then save the finding"
      refute prompt =~ "sends it back"
      assert prompt =~ "A finding shows only its own `evidence`"
      assert prompt =~ "goes in the finding's `evidence`"
      refute prompt =~ "put the pictures you filed for that row next to the finding"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "a first pass has nothing to re-test", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      refute prompt =~ "This change has been QA'd before"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "a later pass is owed a verdict on everything already raised", %{task: task, run: run} do
    [outstanding, dismissed] =
      for finding <- [
            %{
              key: "total-unrounded",
              title: "The total renders as $1234.5",
              check: "A bill's total reads as money",
              screen: "/bills/new",
              severity: :major,
              recommendation: :fix,
              status: :open,
              evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
            },
            %{
              key: "spacing-nit",
              title: "Buttons sit too close",
              check: "The form looks like the rest of the app",
              severity: :nit,
              recommendation: :skip,
              status: :open,
              caused_by_change: false,
              evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
            }
          ] do
        {:ok, saved} = Pipeline.save_qa_finding(task, finding)
        saved
      end

    {:ok, _stopped} = Pipeline.update_run(run, %{status: :finished})
    {:ok, _to_fix} = Pipeline.decide_qa_finding(system_scope(), outstanding, :fix)
    {:ok, _skipped} = Pipeline.decide_qa_finding(system_scope(), dismissed, :skip)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "This change has been QA'd before"
      assert prompt =~ "`total-unrounded` [major, this change, human decided: fix it, status: open]"
      assert prompt =~ "`spacing-nit` [nit, pre-existing, human decided: dismissed, leave it, status: open]"
      assert prompt =~ "(/bills/new)"
      assert prompt =~ "never argue it again"
      assert prompt =~ "save its key again with `save_finding`"
      assert prompt =~ "A finding you save again keeps the `evidence` entries you list"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "a finding nobody has ruled on yet says so", %{task: task, run: run} do
    for finding <- [
          %{
            key: "one",
            title: "One",
            check: "A check",
            severity: :minor,
            recommendation: :fix,
            status: :open,
            evidence: [%{name: "what QA saw", kind: :note, text: "Seen."}]
          }
        ],
        do: {:ok, _saved} = Pipeline.save_qa_finding(task, finding)

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "human decided: not yet decided"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "the plan is the specification when there is one", %{task: task, run: run} do
    {:ok, _plan} =
      %ImplementationPlan{}
      |> ImplementationPlan.changeset(%{
        task_id: task.id,
        content:
          ~s{Add a vendor filter to the invoice index.\n\n```mermaid\nflowchart LR\n  A["InvoicesLive"] --> B["Invoices"]\n```\n\n```elixir\ndef list_invoices(scope, filters)\n```},
        captured_at: DateTime.utc_now()
      })
      |> Repo.insert()

    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "The approved implementation plan the change was built from."
      assert prompt =~ "Add a vendor filter to the invoice index."
      assert prompt =~ ~s(```mermaid\nflowchart LR\n  A["InvoicesLive"] --> B["Invoices"]\n```)
      assert prompt =~ "```elixir\ndef list_invoices(scope, filters)\n```"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  test "and the ticket is the whole of it when there is not", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      assert ["-p", prompt | _rest] = argv
      assert prompt =~ "There is no implementation plan for this ticket"

      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
  end

  describe "what the project has learned" do
    test "the brief carries the rules retrieved with the ticket and the files the change touched", %{
      project: project,
      run: run
    } do
      stub_vertex(%{"lib/rail_web/live/bills_live.ex" => vector([1.0])})

      stub(Rail.Git, :load_diff, fn _scope, _task, :branch ->
        {:ok, [%{path: "lib/rail_web/live/bills_live.ex", rows: []}]}
      end)

      learning(project, %{rule: "Seed bills through the factory", kind: :qa, roles: [:qa]}, embedding: [1.0])

      expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
        assert prompt =~ "- QA: Seed bills through the factory"
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
      assert_received {:embedded, "Invoice filters\n\nFilter invoices by vendor.", "RETRIEVAL_QUERY"}
      assert_received {:embedded, "lib/rail_web/live/bills_live.ex", "RETRIEVAL_QUERY"}
    end

    test "a change with no files, or no worktree, is queried by its ticket alone", %{project: project, run: run} do
      stub_vertex()
      stub(Rail.Git, :load_diff, fn _scope, _task, :branch -> {:error, :no_worktree} end)
      learning(project, %{rule: "Anything", kind: :qa}, embedding: [1.0])

      expect(Tools, :start_os_process, fn %Run{} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, %OsProcess{}} = Pipeline.start_qa_run(run)
      assert_received {:embedded, "Invoice filters" <> _ticket, "RETRIEVAL_QUERY"}
      refute_received {:embedded, _files, _task_type}
    end
  end
end
