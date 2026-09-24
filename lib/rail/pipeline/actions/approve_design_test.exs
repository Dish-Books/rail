defmodule Rail.Pipeline.Actions.ApproveDesignTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    roles =
      Map.new([:design, :architect], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

        {stage, role}
      end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_approve_design_1",
              "identifier" => "APD-1",
              "title" => "Approve Design",
              "description" => "The approved ticket body."
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "The approved ticket body."})
    {:ok, task} = Pipeline.create_task(issue, :design)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    design_dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(design_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(
      Path.join(design_dir, "manifest.json"),
      ~s({"options": [{"key": "cards", "title": "Cards", "summary": "Big tiles."}, {"key": "table", "title": "Table"}]})
    )

    File.write!(Path.join(design_dir, "cards.html"), "<h1>Cards</h1>")
    File.write!(Path.join(design_dir, "cards.png"), "png bytes")
    File.write!(Path.join(design_dir, "picked"), "cards")

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: roles[:design].id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_approve_design",
        started_at: DateTime.utc_now()
      })

    %{task: task, roles: roles, run: run, design_dir: design_dir}
  end

  test "publishes the picked screenshot on the issue and hands the task to the architect", %{
    task: task,
    roles: roles,
    run: run
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "fileUpload" => %{
            "success" => true,
            "uploadFile" => %{
              "uploadUrl" => "https://uploads.linear.app/put/apd-1",
              "assetUrl" => "https://uploads.linear.app/assets/apd-1-cards.png",
              "headers" => []
            }
          }
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.method == "PUT"
      assert {:ok, "png bytes", _conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned, task: task}} end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.approve_design(run)

    assert %Task{stage: :architect} = Repo.reload!(task)
    assert Repo.get_by(Run, task_id: task.id, role_id: roles[:architect].id)

    description =
      "The approved ticket body.\n\n## Design: Cards\n\nBig tiles.\n\n![Cards](https://uploads.linear.app/assets/apd-1-cards.png)"

    assert %Issue{description: ^description} = Repo.get!(Issue, task.issue_id)
  end

  test "a design nobody picked is not approved", %{run: run, design_dir: dir} do
    File.rm!(Path.join(dir, "picked"))

    assert {:error, :nothing_picked} = Pipeline.approve_design(run)
  end

  test "a picked design with no screenshot is not approved", %{run: run, design_dir: dir} do
    File.rm!(Path.join(dir, "cards.png"))

    assert {:error, :screenshot_missing} = Pipeline.approve_design(run)
  end

  test "a screenshot older than its page is not published", %{task: task, run: run, design_dir: dir} do
    File.touch!(Path.join(dir, "cards.html"), System.os_time(:second) + 60)

    assert {:error, :stale_screenshot} = Pipeline.approve_design(run)
    assert %Task{stage: :design} = Repo.reload!(task)
  end

  test "an upload Linear refuses leaves the task at design", %{task: task, run: run} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"fileUpload" => %{"success" => false}}})
    end)

    assert {:error, _reason} = Pipeline.approve_design(run)
    assert %Task{stage: :design} = Repo.reload!(task)
    assert %Issue{description: "The approved ticket body."} = Repo.get!(Issue, task.issue_id)
  end

  test "nothing is approved while the designer is still working", %{run: run} do
    {:ok, working} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.approve_design(working)
  end

  test "a task past design has nothing left to approve", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :architect})

    assert {:error, {:invalid_stage, :architect}} = Pipeline.approve_design(run)
  end
end
