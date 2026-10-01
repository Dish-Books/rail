defmodule Rail.Pipeline.Actions.MarkPullRequestReadyTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup {Req.Test, :verify_on_exit!}

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_mrk",
        identifier: "MRK-1",
        title: "Vendor filter",
        url: "https://linear.app/rail/issue/MRK-1",
        state: :in_progress
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :qa,
          worktree_name: "mrk-1",
          worktree_path: "/tmp/repos/test-seed/.worktrees/mrk-1",
          scratch_path: Path.join(System.tmp_dir!(), "mark_ready_#{System.unique_integer([:positive])}"),
          pr_number: 7,
          pr_url: "https://github.com/example/test-seed/pull/7",
          pr_is_draft: true
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    %{task: task, run: run}
  end

  test "takes the draft out of draft and posts each open question for the lead as its own comment", %{
    task: task,
    run: run
  } do
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

    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content: "### Approach\n\n- Filter.\n\n### Assumptions\n\n- Vendors are filtered by name.\n",
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    test = self()

    Req.Test.expect(Client, 6, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "draft" => true, "body" => "Rail's placeholder"})

        {"POST", "/graphql"} ->
          send(test, :marked_ready)
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})

        {"POST", "/repos/example/test-seed/issues/7/comments"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:comment, Jason.decode!(body)["body"]})
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

        {method, path} ->
          send(test, {:unexpected, method, path})
          Req.Test.json(conn, %{})
      end
    end)

    assert {:ok, %Task{pr_is_draft: false}} = Pipeline.mark_pull_request_ready(system_scope(), task)
    assert_received :marked_ready

    assert_received {:comment,
                     "**Open question for the lead**\n\nWhich vendor list?\n\n- Asked while wiring the filter.\n- Option: All vendors\n- Option: Active only"}

    assert_received {:comment, "**Open question for the lead**\n\nKeep the old sort?"}

    assert_received {:comment,
                     "**Assumption in the approved plan, for the lead to confirm**\n\nVendors are filtered by name."}

    refute_received {:comment, _another}
    refute_received {:unexpected, _method, _path}
    assert %Task{pr_is_draft: false} = Repo.reload!(task)
  end

  test "a task whose engineer is still running cannot be marked ready", %{task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :not_markable} = Pipeline.mark_pull_request_ready(system_scope(), task)
    assert %Task{pr_is_draft: true} = Repo.reload!(task)
  end

  test "a task with no pull request cannot be marked ready", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: nil, pr_url: nil, pr_is_draft: nil})

    assert {:error, :not_markable} = Pipeline.mark_pull_request_ready(system_scope(), task)
  end

  # A second press reads the task again, so a page still showing the button posts nothing twice.
  test "a pull request already marked ready is not marked again", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_is_draft: false})

    assert {:error, :not_markable} = Pipeline.mark_pull_request_ready(system_scope(), %{task | pr_is_draft: true})
  end

  test "a press that loses the race to another posts nothing", %{task: task, run: run} do
    %Question{}
    |> Question.changeset(%{task_id: task.id, run_id: run.id, prompt: "Which vendor list?", status: :pending})
    |> Repo.insert!()

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "draft" => true})

        # The other press flips the flag while this one waits on GitHub.
        {"POST", "/graphql"} ->
          {:ok, _won} = Pipeline.update_task(task, %{pr_is_draft: false})
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})
      end
    end)

    assert {:ok, %Task{pr_is_draft: false}} = Pipeline.mark_pull_request_ready(system_scope(), task)
  end

  test "a ready call GitHub refuses leaves the draft as it was and posts nothing", %{task: task, run: run} do
    %Question{}
    |> Question.changeset(%{task_id: task.id, run_id: run.id, prompt: "Which vendor list?", status: :pending})
    |> Repo.insert!()

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "draft" => true})

        {"POST", "/graphql"} ->
          conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Forbidden"})
      end
    end)

    assert {:error, {:github_api_error, 403, _body}} = Pipeline.mark_pull_request_ready(system_scope(), task)
    assert %Task{pr_is_draft: true} = Repo.reload!(task)
  end

  test "a comment GitHub refuses is logged and the rest are still posted", %{task: task, run: run} do
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

        {"GET", "/repos/example/test-seed/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "draft" => true})

        {"POST", "/graphql"} ->
          Req.Test.json(conn, %{"data" => %{"markPullRequestReadyForReview" => %{}}})

        {"POST", "/repos/example/test-seed/issues/7/comments"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          comment = Jason.decode!(body)["body"]
          send(test, {:comment, comment})

          if comment =~ "Refused?",
            do: conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Forbidden"}),
            else: conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert {:ok, %Task{pr_is_draft: false}} = Pipeline.mark_pull_request_ready(system_scope(), task)
           end) =~ "Could not comment on example/test-seed#7"

    assert_received {:comment, "**Open question for the lead**\n\nRefused?"}
    assert_received {:comment, "**Open question for the lead**\n\nPosted?"}
  end

  test "a pull request someone readied on GitHub is only caught up with", %{task: task, run: run} do
    %Question{}
    |> Question.changeset(%{task_id: task.id, run_id: run.id, prompt: "Which vendor list?", status: :pending})
    |> Repo.insert!()

    test = self()

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "node_id" => "PR_kw7", "draft" => false})

        {"POST", "/repos/example/test-seed/issues/7/comments"} ->
          send(test, :commented)
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end
    end)

    assert {:ok, %Task{pr_is_draft: false}} = Pipeline.mark_pull_request_ready(system_scope(), task)
    assert_received :commented
  end

  test "a pull request GitHub cannot find is an error, and the task is left as it was", %{task: task} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))

    assert {:error, {:github_api_error, 404, _body}} = Pipeline.mark_pull_request_ready(system_scope(), task)
    assert %Task{pr_is_draft: true} = Repo.reload!(task)
  end
end
