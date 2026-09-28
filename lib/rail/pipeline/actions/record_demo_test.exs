defmodule Rail.Pipeline.Actions.RecordDemoTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Demo Project",
        github_repo: "org/demo",
        github_installation_id: 47_091,
        linear_team_key: "DMO",
        default_branch: "main",
        clone_path: "/tmp/repos/demo"
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :demo,
        name: "demo role",
        model: "claude-opus-5-5",
        system_prompt: "You are the demo agent."
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_dmo",
        identifier: "DMO-1",
        title: "Demo",
        url: "https://linear.app/rail/issue/DMO-1",
        state: :backlog
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :demo,
          worktree_name: "dmo-1",
          worktree_path: create_temp_git_repo(),
          scratch_path: Path.join(System.tmp_dir!(), "demo_#{System.unique_integer([:positive])}")
        },
        project.id
      )
      |> Repo.insert!()

    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, role: role}
  end

  test "records a demo the stage was entered without", %{task: task} do
    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{status: :running}} = Pipeline.record_demo(system_scope(), task)
  end

  test "records one already recorded again, as a fresh take", %{task: task, role: role} do
    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_demo",
        started_at: DateTime.utc_now()
      })

    File.mkdir_p!(Path.join(task.scratch_path, "demo"))
    File.write!(Path.join([task.scratch_path, "demo", "demo.webm"]), "video")
    {:ok, task} = Pipeline.update_task(task, %{demo_skipped_at: DateTime.utc_now()})

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Record the walkthrough again, as a fresh take"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{status: :running, stage_outcome: :in_progress}} = Pipeline.record_demo(system_scope(), task)
    assert %Task{demo_skipped_at: nil} = Repo.reload!(task)
  end

  test "settles a demo as not needed, which is the demo done", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"GET", "/repos/org/demo/pulls/7"} -> Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7"})
        {"POST", "/graphql"} -> Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert {:ok, %Run{id: run_id, status: :finished, stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)
    assert %Task{demo_skipped_at: %DateTime{}, pr_is_draft: false} = Repo.reload!(task)
    assert [%RunEvent{run_id: ^run_id, line: "[human] No demo is needed for this change."}] = Repo.all(RunEvent)
  end

  test "settling a demo that already ran keeps its run", %{task: task, role: role} do
    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :in_progress,
        error: "The browser painted no frames, so there is nothing to watch.",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Run{id: ^run_id, stage_outcome: :done, error: nil}} = Pipeline.skip_demo(system_scope(), task)
  end

  test "a skipped demo replaces Rail's placeholder with a description, and no demo section", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})
    File.mkdir_p!(Path.join(task.scratch_path, "pr"))
    File.write!(Path.join([task.scratch_path, "pr", "DMO-1.md"]), "- Adds a vendor filter.\n- Keeps the old sort.\n")
    File.mkdir_p!(Path.join(task.scratch_path, "qa"))

    File.write!(
      Path.join([task.scratch_path, "qa", "DMO-1.json"]),
      ~s({"verdict": "pass", "summary": "The filter\\nworks.", "findings": []})
    )

    placeholder =
      "https://linear.app/rail/issue/DMO-1\n\nOpened by Rail as a draft. It is marked ready for review once the change is ready to merge."

    test = self()

    Req.Test.expect(Client, 4, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/org/demo/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "body" => placeholder})

        {"PATCH", "/repos/org/demo/pulls/7"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:description, Jason.decode!(body)["body"]})
          Req.Test.json(conn, %{"number" => 7})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)

    assert_received {:description,
                     "https://linear.app/rail/issue/DMO-1\n\n- Adds a vendor filter.\n- Keeps the old sort.\n\n**QA:** Passed. The filter works."}

    assert %Task{pr_is_draft: false} = Repo.reload!(task)
  end

  # Line endings are GitHub's to choose, so a placeholder that comes back with
  # CRLFs is still Rail's own.
  test "with nothing from QA the description is the ticket link alone", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})

    placeholder =
      "https://linear.app/rail/issue/DMO-1\r\n\r\nOpened by Rail as a draft. It is marked ready for review once the change is ready to merge.\r\n"

    Req.Test.expect(Client, 4, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/org/demo/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "body" => placeholder})

        {"PATCH", "/repos/org/demo/pulls/7"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert %{"body" => "https://linear.app/rail/issue/DMO-1"} = Jason.decode!(body)
          Req.Test.json(conn, %{"number" => 7})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)
    Req.Test.verify!(Client)
  end

  test "a blank description file and a QA report with no verdict add nothing to the description", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})
    File.mkdir_p!(Path.join(task.scratch_path, "pr"))
    File.write!(Path.join([task.scratch_path, "pr", "DMO-1.md"]), "  \n\n")
    File.mkdir_p!(Path.join(task.scratch_path, "qa"))
    File.write!(Path.join([task.scratch_path, "qa", "DMO-1.json"]), ~s({"summary": "Ran out of time.", "findings": []}))

    placeholder =
      "https://linear.app/rail/issue/DMO-1\n\nOpened by Rail as a draft. It is marked ready for review once the change is ready to merge."

    # One call at a time, in order: the description is written before the pull
    # request leaves draft.
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "node_id" => "PR_kw7", "body" => placeholder}))

    Req.Test.expect(Client, fn conn ->
      assert {"PATCH", "/repos/org/demo/pulls/7"} = {conn.method, conn.request_path}
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"body" => "https://linear.app/rail/issue/DMO-1"} = Jason.decode!(body)
      Req.Test.json(conn, %{"number" => 7})
    end)

    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/graphql"
      Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
    end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)
    assert %Task{pr_is_draft: false} = Repo.reload!(task)
  end

  test "each open question and plan assumption becomes its own comment, not part of the description", %{
    task: task,
    role: role
  } do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    for {prompt, status, extra} <- [
          {"Which vendor list?", :pending,
           %{context_summary: "Asked while wiring the filter.", options: ["All vendors", "Active only"]}},
          {"Keep the old sort?", :unanswered, %{}},
          {"Answered already?", :answered, %{answer: "Yes"}},
          {"Dismissed already?", :dismissed, %{}}
        ] do
      %Question{}
      |> Question.changeset(Map.merge(%{task_id: task.id, run_id: run.id, prompt: prompt, status: status}, extra))
      |> Repo.insert!()
    end

    {:ok, _plan} =
      %ImplementationPlan{}
      |> ImplementationPlan.changeset(%{
        task_id: task.id,
        content: "### Approach\n\n- Filter.\n\n### Assumptions\n\n- Vendors are filtered by name.\n",
        captured_at: DateTime.utc_now()
      })
      |> Repo.insert()

    placeholder =
      "https://linear.app/rail/issue/DMO-1\n\nOpened by Rail as a draft. It is marked ready for review once the change is ready to merge."

    test = self()

    Req.Test.expect(Client, 7, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/org/demo/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "body" => placeholder})

        {"PATCH", "/repos/org/demo/pulls/7"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:description, Jason.decode!(body)["body"]})
          Req.Test.json(conn, %{"number" => 7})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})

        {"POST", "/repos/org/demo/issues/7/comments"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:comment, Jason.decode!(body)["body"]})
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end
    end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)

    assert_received {:description, description}
    refute description =~ "Which vendor list?"
    refute description =~ "Keep the old sort?"
    refute description =~ "Vendors are filtered by name."

    assert_received {:comment,
                     "**Open question for the lead**\n\nWhich vendor list?\n\n- Asked while wiring the filter.\n- Option: All vendors\n- Option: Active only"}

    assert_received {:comment, "**Open question for the lead**\n\nKeep the old sort?"}

    assert_received {:comment,
                     "**Assumption in the approved plan, for the lead to confirm**\n\nVendors are filtered by name."}

    refute_received {:comment, _another}
  end

  test "a comment GitHub refuses is logged and the rest are still posted", %{task: task, role: role} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    for prompt <- ["Refused?", "Posted?"] do
      %Question{}
      |> Question.changeset(%{task_id: task.id, run_id: run.id, prompt: prompt, status: :pending})
      |> Repo.insert!()
    end

    test = self()

    Req.Test.expect(Client, 5, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/org/demo/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "body" => "Written by a person."})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})

        {"POST", "/repos/org/demo/issues/7/comments"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          comment = Jason.decode!(body)["body"]
          send(test, {:comment, comment})

          if comment =~ "Refused?",
            do: conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Forbidden"}),
            else: conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert {:ok, %Run{stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)
           end) =~ "Could not comment on org/demo#7"

    assert_received {:comment, "**Open question for the lead**\n\nRefused?"}
    assert_received {:comment, "**Open question for the lead**\n\nPosted?"}
  end

  # A pull request Rail adopted from a person was never Rail's placeholder either.
  test "a description a person wrote is left as it is, and the pull request still comes out of draft", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/org/demo/pulls/7"} ->
          body =
            "https://linear.app/rail/issue/DMO-1\n\nOpened by Rail as a draft. Ada added the rollout steps.\n\n## Demo\n\n[Watch the demo](a.webm)"

          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "body" => body})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)
    assert %Task{pr_is_draft: false} = Repo.reload!(task)
  end

  test "a description GitHub will not take never holds the pull request in draft", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})

    placeholder =
      "https://linear.app/rail/issue/DMO-1\n\nOpened by Rail as a draft. It is marked ready for review once the change is ready to merge."

    Req.Test.expect(Client, 4, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/org/demo/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "body" => placeholder})

        {"PATCH", "/repos/org/demo/pulls/7"} ->
          conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "Validation Failed"})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert {:ok, %Run{stage_outcome: :done}} = Pipeline.skip_demo(system_scope(), task)
           end) =~ "Could not describe org/demo#7"

    assert %Task{pr_is_draft: false} = Repo.reload!(task)
  end

  test "neither is offered anywhere but the demo stage, or while something runs", %{task: task, role: role} do
    {:ok, at_qa} = Pipeline.update_task(task, %{stage: :qa})
    assert {:error, {:invalid_stage, :qa}} = Pipeline.record_demo(system_scope(), at_qa)
    assert {:error, {:invalid_stage, :qa}} = Pipeline.skip_demo(system_scope(), at_qa)

    {:ok, _task} = Pipeline.update_task(at_qa, %{stage: :demo})

    {:ok, _run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    assert {:error, :stage_running} = Pipeline.record_demo(system_scope(), task)
    assert {:error, :stage_running} = Pipeline.skip_demo(system_scope(), task)
  end
end
