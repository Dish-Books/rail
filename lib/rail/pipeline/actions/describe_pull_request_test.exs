defmodule Rail.Pipeline.Actions.DescribePullRequestTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup {Req.Test, :verify_on_exit!}

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_dsc",
        identifier: "DSC-1",
        title: "Vendor filter",
        description: "Filter bills by vendor.",
        url: "https://linear.app/rail/issue/DSC-1",
        state: :in_progress
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "dsc-1",
          worktree_path: "/tmp/repos/test-seed/.worktrees/dsc-1",
          scratch_path: Path.join(System.tmp_dir!(), "describe_#{System.unique_integer([:positive])}"),
          pr_number: 7,
          pr_url: "https://github.com/example/test-seed/pull/7",
          pr_is_draft: true
        },
        project.id
      )
      |> Repo.insert!()

    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    placeholder =
      "https://linear.app/rail/issue/DSC-1\n\nOpened by Rail as a draft. It is marked ready for review once the change is ready to merge."

    written = """
    ## Summary

    ```mermaid
    flowchart LR
      Bills --> VendorFilter
    ```

    ## Evidence

    **Before:** every bill is listed.

    **After:** only Sysco's bills are listed.

    ## Merge Danger

    **Door:** two-way, nothing is stored.

    **Blast Radius:** the bills page.
    """

    %{
      project: project,
      task: task,
      run: run,
      placeholder: placeholder,
      written: written,
      pr_file: Path.join([task.scratch_path, "pr", "DSC-1.md"])
    }
  end

  test "an agent with no role writes the description over Rail's placeholder", %{
    task: task,
    placeholder: placeholder,
    written: written,
    pr_file: file
  } do
    %ImplementationPlan{}
    |> ImplementationPlan.changeset(%{
      task_id: task.id,
      content: "### Approach\n\nAdd a vendor select to the bills page.\n",
      captured_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "body" => placeholder}))

    expect(Tools, :run_agent, fn backend, argv, opts ->
      assert %{name: :claude} = backend
      assert ["-p", prompt, "--model", "claude-opus-5-5", "--effort", "high" | _rest] = argv
      refute "--append-system-prompt" in argv

      assert %{cd: "/tmp/repos/test-seed/.worktrees/dsc-1", timeout: 900_000, env: %{"RAIL_MCP_TOKEN" => token}} =
               Map.new(opts)

      assert byte_size(token) > 0

      assert prompt =~ "Vendor filter"
      assert prompt =~ "Add a vendor select to the bills page."
      assert prompt =~ "git diff origin/main...HEAD"
      assert prompt =~ "/tmp/repos/test-seed/.worktrees/dsc-1/CONTEXT.md"
      assert prompt =~ file
      assert prompt =~ "Filter bills by vendor."

      File.write!(file, written)
      {:ok, ""}
    end)

    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "body" => placeholder}))

    Req.Test.expect(Client, fn conn ->
      assert {"PATCH", "/repos/example/test-seed/pulls/7"} = {conn.method, conn.request_path}
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      expected = "https://linear.app/rail/issue/DSC-1\n\n" <> String.trim(written)
      assert %{"body" => ^expected} = Jason.decode!(body)
      Req.Test.json(conn, %{"number" => 7})
    end)

    assert :ok = Pipeline.describe_pull_request(task)
  end

  test "the brief points the agent at the CI log, when the project has CI", %{
    project: project,
    task: task,
    run: run,
    placeholder: placeholder,
    written: written,
    pr_file: file
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: task.id,
      kind: :ci,
      exit_code: 0,
      stream_path: "/tmp/describe-ci.log",
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, 2, &Req.Test.json(&1, %{"number" => 7, "body" => placeholder}))
    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7}))

    expect(Tools, :run_agent, fn _backend, ["-p", prompt | _rest], _opts ->
      assert prompt =~ "/tmp/describe-ci.log"
      File.write!(file, written)
      {:ok, ""}
    end)

    assert :ok = Pipeline.describe_pull_request(task)
  end

  # The agent runs for minutes, and a person can rewrite the body in the meantime.
  test "a body a person edited while the agent ran is left as they wrote it", %{
    task: task,
    placeholder: placeholder,
    written: written,
    pr_file: file
  } do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "body" => placeholder}))

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(file, written)
      {:ok, ""}
    end)

    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "body" => "Ada wrote this one."}))

    assert :ok = Pipeline.describe_pull_request(task)
  end

  test "a pull request already out of draft with the placeholder is still described", %{
    task: task,
    placeholder: placeholder,
    written: written,
    pr_file: file
  } do
    {:ok, task} = Pipeline.update_task(task, %{pr_is_draft: false})
    test = self()

    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, 2, &Req.Test.json(&1, %{"number" => 7, "draft" => false, "body" => placeholder}))

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(file, written)
      {:ok, ""}
    end)

    Req.Test.expect(Client, fn conn ->
      send(test, :described)
      Req.Test.json(conn, %{"number" => 7})
    end)

    assert :ok = Pipeline.describe_pull_request(task)
    assert_received :described
  end

  test "a description missing one of its sections is not written", %{
    task: task,
    placeholder: placeholder,
    written: written,
    pr_file: file
  } do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "body" => placeholder}))

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(file, String.replace(written, "## Merge Danger", "## Risk"))
      {:ok, ""}
    end)

    assert {:error, :incomplete_description} = Pipeline.describe_pull_request(task)
  end

  # A file from an earlier attempt is not this agent's answer.
  test "an agent that writes nothing is an incomplete description, whatever an earlier attempt left", %{
    task: task,
    placeholder: placeholder,
    written: written,
    pr_file: file
  } do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, written)

    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "body" => placeholder}))
    expect(Tools, :run_agent, fn _backend, _argv, _opts -> {:ok, ""} end)

    assert {:error, :incomplete_description} = Pipeline.describe_pull_request(task)
  end

  test "an agent that fails is an error, and nothing is written", %{task: task, placeholder: placeholder} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "body" => placeholder}))
    expect(Tools, :run_agent, fn _backend, _argv, _opts -> {:error, {:exit, 1}} end)

    assert {:error, {:exit, 1}} = Pipeline.describe_pull_request(task)
  end

  # GitHub chooses the line endings, and a demo recorded first is already under the placeholder.
  test "a demo section already on the placeholder is kept under the description", %{
    task: task,
    placeholder: placeholder,
    written: written,
    pr_file: file
  } do
    demo = "## Demo\n\n[Watch the demo](https://uploads.linear.app/a.webm)"
    linked = String.replace("#{placeholder}\n\n#{demo}", "\n", "\r\n")

    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, 2, &Req.Test.json(&1, %{"number" => 7, "body" => linked}))

    expect(Tools, :run_agent, fn _backend, _argv, _opts ->
      File.write!(file, written)
      {:ok, ""}
    end)

    Req.Test.expect(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      expected = "https://linear.app/rail/issue/DSC-1\n\n#{String.trim(written)}\n\n#{demo}"
      assert %{"body" => ^expected} = Jason.decode!(body)
      Req.Test.json(conn, %{"number" => 7})
    end)

    assert :ok = Pipeline.describe_pull_request(task)
  end

  # Rail adopts an open pull request a person opened, and that body was never Rail's.
  test "a body that is not Rail's placeholder never runs the agent", %{task: task} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &Req.Test.json(&1, %{"number" => 7, "body" => "Ada's own description."}))
    reject(&Tools.run_agent/3)

    assert :ok = Pipeline.describe_pull_request(task)
  end

  test "a pull request GitHub cannot read is an error", %{task: task} do
    Req.Test.expect(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))
    reject(&Tools.run_agent/3)

    assert {:error, {:github_api_error, 404, _body}} = Pipeline.describe_pull_request(task)
  end
end
