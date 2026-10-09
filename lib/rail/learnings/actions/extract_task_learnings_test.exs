defmodule Rail.Learnings.Actions.ExtractTaskLearningsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Learnings.Schemas.ProcessedPullRequest
  alias Rail.Learnings.Workers.CollectPullRequest
  alias Rail.Pipeline
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Users

  setup %{project: project} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "ext-1-#{id}",
        login: "dana-#{id}",
        name: "Dana Okafor",
        email: "dana-#{id}@ext.example"
      })

    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    task = learnings_task(project, "EXT-1", :review)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, worktree_path: System.tmp_dir!()})
    on_exit(fn -> File.rm_rf(Path.join([Rail.scratch_root(), project.id, "learnings", "tasks", task.id])) end)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    stub(Rail.Git, :branch_fingerprint, fn _worktree -> %{head_sha: "basesha"} end)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: lead.id, status: :finished, started_at: DateTime.utc_now()})

    Pipeline.append_run_events(run.id, nil, ["[human] Use the factory, please"])

    code = %{
      kind: :code,
      raised_by: :code_reviewer,
      problem: "A task with no worktree crashes the page.",
      file: "lib/a.ex",
      line: 3,
      fix: "Guard the nil in the action.",
      why: "It crashes.",
      rule: "Every caller handles a missing worktree.",
      severity: :major,
      recommendation: :fix,
      places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}],
      evidence: [%{name: "The clause", kind: :code, file: "lib/a.ex", line: 3}]
    }

    {:ok, finding} = Pipeline.save_finding(task, Map.merge(code, %{key: "nil", title: "Nil is not handled"}))
    {:ok, _decided} = Pipeline.decide_finding(Rail.Scope.for_user(user), finding, :fix)

    {:ok, question} =
      Pipeline.register_question(%{run | task: Repo.preload(task, :issue)}, %DetectedQuestion{
        prompt: "Indigo or blue?"
      })

    {:ok, _answered} = Pipeline.answer_question(Rail.Scope.for_user(user), question, "Blue.")
    rule = learning(project, %{rule: "Use the factory", kind: :convention})
    calibration = learning(project, %{rule: "Don't flag docs", kind: :calibration})

    {:ok, _doc} =
      Pipeline.save_finding(
        task,
        Map.merge(code, %{key: "doc", title: "Missing @doc", recommendation: :skip, checklist_rule: calibration.id})
      )

    {:ok, _factory} =
      Pipeline.save_finding(
        task,
        Map.merge(code, %{key: "factory", title: "Repo.insert! in a test", checklist_rule: rule.id})
      )

    {:ok, _total} =
      Pipeline.save_finding(task, %{
        key: "total",
        kind: :screen,
        raised_by: :explorer,
        title: "The total is unrounded",
        problem: "Every bill shows $1234.5.",
        screen: "Invoices",
        steps: ["Open an invoice"],
        check: "totals",
        fix: "Round the total to cents.",
        why: "Money reads in cents.",
        rule: "Totals show two decimals.",
        severity: :major,
        recommendation: :fix,
        places: [%{screen: "Invoices"}],
        evidence: [%{name: "What QA saw", kind: :note, text: "Seen."}]
      })

    {:ok, %{head: "basesha"}} = Pipeline.save_review(task)

    {:ok, _pending} =
      Pipeline.register_question(%{run | task: Repo.preload(task, :issue)}, %DetectedQuestion{prompt: "Behind a flag?"})

    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content: "Extend the invoices module.",
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-seed/pulls/7" ->
          Req.Test.json(conn, %{"number" => 7, "head" => %{"sha" => "headsha"}})

        "/repos/example/test-seed/compare/basesha...headsha" ->
          Req.Test.json(conn, %{"files" => [%{"filename" => "lib/a.ex", "patch" => "-Repo.insert!\n+Factory.insert"}]})
      end
    end)

    %{task: task, rule: rule, calibration: calibration}
  end

  test "the curator reads what happened and its observations are stored once, with the marker set", %{
    task: task,
    rule: %{id: rule_id} = rule,
    calibration: %{id: calibration_id}
  } do
    test = self()

    expect(Tools, :run_agent, fn _role, argv, opts ->
      dir = opts[:cd]

      send(
        test,
        {:files,
         Map.new(
           ["findings.md", "questions.md", "compare.diff", "rules.md", "ticket.md", "plan.md"],
           &{&1, File.read!(Path.join(dir, &1))}
         )}
      )

      send(test, {:transcripts, dir |> Path.join("transcripts/*") |> Path.wildcard() |> Enum.map(&File.read!/1)})
      send(test, {:argv, Enum.join(argv, " ")})

      File.write!(
        Path.join(dir, "result.json"),
        Jason.encode!(%{
          "observations" => [
            %{"text" => "Tests use the factory", "excerpt" => "Factory.insert", "rule" => rule.id},
            %{"text" => "Ids from elsewhere are dropped", "rule" => "lrn_foreign"},
            %{"text" => "  "},
            "not an observation"
          ]
        })
      )

      {:ok, ""}
    end)

    assert {:ok, %Task{learnings_extracted_at: %DateTime{}}} = Learnings.extract_task_learnings(task)

    assert_received {:files, files}
    assert files["findings.md"] =~ "Decided: fix by Dana Okafor"
    assert files["questions.md"] =~ "answered by Dana Okafor: Blue."
    assert files["compare.diff"] =~ "+Factory.insert"
    assert files["plan.md"] == "Extend the invoices module."
    assert files["findings.md"] =~ "Suppressed by rule #{calibration_id}."
    assert files["findings.md"] =~ "Raised from rule #{rule_id}."
    assert files["findings.md"] =~ "## Round 1, screen: The total is unrounded"
    assert files["findings.md"] =~ "Rule: Totals show two decimals."
    assert files["questions.md"] =~ "pending, answered by nobody"
    assert files["rules.md"] =~ rule.id
    assert_received {:transcripts, [transcript]}
    assert transcript =~ "Use the factory, please"
    assert_received {:argv, argv}
    assert argv =~ "Comments people left on the pull request in GitHub are collected separately"

    assert_enqueued(worker: CollectPullRequest, args: %{project_id: task.project_id, number: 7})

    assert [
             %Observation{
               source_kind: :extraction,
               text: "Ids from elsewhere are dropped",
               learning_id: nil,
               abandoned: false
             },
             %Observation{text: "Tests use the factory", excerpt: "Factory.insert", learning_id: ^rule_id}
           ] =
             Repo.all(
               from o in Observation, where: o.task_id == ^task.id and o.source_kind == :extraction, order_by: o.text
             )
  end

  test "an abandoned task's observations say so, and a processed PR is not queued again", %{project: project, task: task} do
    {:ok, _issue} = Issues.update_issue(task.issue, %{state: :canceled})
    Repo.insert!(%ProcessedPullRequest{project_id: project.id, number: 7})

    expect(Tools, :run_agent, fn _role, _argv, opts ->
      File.write!(Path.join(opts[:cd], "result.json"), ~s({"observations": [{"text": "It was the wrong fix"}]}))
      {:ok, ""}
    end)

    assert {:ok, _extracted} = Learnings.extract_task_learnings(task)

    assert [%Observation{abandoned: true}] =
             Repo.all(from o in Observation, where: o.task_id == ^task.id and o.source_kind == :extraction)

    refute_enqueued(worker: CollectPullRequest)
  end

  test "a second extraction, after a reopen or from the backfill, fetches nothing and runs no agent", %{task: task} do
    expect(Tools, :run_agent, fn _role, _argv, opts ->
      File.write!(Path.join(opts[:cd], "result.json"), ~s({"observations": []}))
      {:ok, ""}
    end)

    {:ok, _first} = Learnings.extract_task_learnings(task)
    reject(&Tools.run_agent/3)
    Req.Test.stub(Client, fn _conn -> flunk("an extracted task was fetched from GitHub again") end)

    assert {:ok, %Task{learnings_extracted_at: %DateTime{}}} = Learnings.extract_task_learnings(task)
  end

  test "a failed pass, or a project with no curator role, sets no marker and records nothing", %{task: task} do
    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:ok, ""} end)
    assert {:error, :unreadable} = Learnings.extract_task_learnings(task)

    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, :timeout} end)
    assert {:error, :timeout} = Learnings.extract_task_learnings(task)

    no_account =
      "No signed-in account offers claude-opus-5-5. Sign one in on Settings › Backends, or pick another model for Curator."

    expect(Tools, :run_agent, fn _role, _argv, _opts -> {:error, no_account} end)
    assert {:error, ^no_account} = Learnings.extract_task_learnings(task)

    stub(Roles, :get_role, fn _by -> {:error, :role_not_found} end)
    assert {:error, :no_role} = Learnings.extract_task_learnings(task)

    assert %Task{learnings_extracted_at: nil} = Repo.reload!(task)
    assert [] = Repo.all(from o in Observation, where: o.task_id == ^task.id and o.source_kind == :extraction)
  end

  test "a task that never opened a pull request is read without one", %{project: project} do
    plain = learnings_task(project, "EXT-2")

    expect(Tools, :run_agent, fn _role, _argv, opts ->
      refute File.exists?(Path.join(opts[:cd], "compare.diff"))
      File.write!(Path.join(opts[:cd], "result.json"), ~s({"observations": []}))
      {:ok, ""}
    end)

    assert {:ok, %Task{learnings_extracted_at: %DateTime{}}} = Learnings.extract_task_learnings(plain)
    refute_enqueued(worker: CollectPullRequest)
  end

  test "the task's folder is gone after the pass, whether it finished or failed", %{project: project} do
    test = self()
    finished = learnings_task(project, "EXT-3")
    failing = learnings_task(project, "EXT-4")

    expect(Tools, :run_agent, fn _role, _argv, opts ->
      send(test, {:dir, opts[:cd]})
      File.write!(Path.join(opts[:cd], "result.json"), ~s({"observations": []}))
      {:ok, ""}
    end)

    assert {:ok, _extracted} = Learnings.extract_task_learnings(finished)
    assert_received {:dir, dir}
    refute File.exists?(dir)

    expect(Tools, :run_agent, fn _role, _argv, opts ->
      send(test, {:dir, opts[:cd]})
      {:error, {:exit, 1, ""}}
    end)

    assert {:error, {:exit, 1, nil}} = Learnings.extract_task_learnings(failing)
    assert_received {:dir, failed_dir}
    refute File.exists?(failed_dir)
  end
end
