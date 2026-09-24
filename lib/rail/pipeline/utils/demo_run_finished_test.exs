defmodule Rail.Pipeline.Utils.DemoRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.DemoRunFinished

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :demo)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dfn_1", "identifier" => "DFN-1", "title" => "Demo Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Demo Finished"})
    {:ok, task} = Pipeline.create_task(issue, :demo)
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(demo_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_demo_finished",
        started_at: DateTime.utc_now()
      })

    %{task: task, run: Repo.preload(run, [:task, :role]), demo_dir: demo_dir}
  end

  test "a run that filmed and wrote up encodes and moves nothing", %{task: task, run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "DFN-1.json"), ~s({"title": "Filters", "summary": "Invoices filter by vendor."}))

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    assert %Run{error: nil} = demo_run_finished(run, [])
    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  # The encode squeezes out the time nothing happened, so where a caption plays is
  # no longer where it was said. Both are kept: the player wants the first, and
  # the next encode wants the second.
  test "each caption learns where it plays in the video, and keeps where it was said", %{
    task: task,
    run: run,
    demo_dir: demo_dir
  } do
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "DFN-1.json"), ~s({"title": "Filters", "summary": "Invoices filter by vendor."}))

    File.write!(Path.join(demo_dir, "captions.jsonl"), """
    {"at_ms": 0, "text": "Starting on the bills page", "criterion": null}
    {"at_ms": 95000, "text": "Saved exactly as entered", "criterion": "A bill saves"}
    """)

    stub(Tools, :stop_browser_recording, fn %Task{} -> nil end)

    # Each caption goes in with its reading time, a few words a second.
    expect(Tools, :encode_recording, fn ^demo_dir, [{0, 2_000}, {95_000, 2_000}] ->
      {:ok, Path.join(demo_dir, "demo.webm"), [0, 31_000]}
    end)

    assert %Run{error: nil} = demo_run_finished(run, [])

    assert [
             %DemoBeat{at_ms: 0, recorded_ms: 0, text: "Starting on the bills page"},
             %DemoBeat{at_ms: 31_000, recorded_ms: 95_000, criterion: "A bill saves"}
           ] = Pipeline.list_demo_beats(task)
  end

  # A run messaged after it finished has already stopped its recorder, and the
  # take it recorded is still there to encode again.
  test "a take already stopped is encoded again from where it was recorded", %{run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "DFN-1.json"), ~s({"title": "Filters", "summary": "Invoices filter by vendor."}))

    expect(Tools, :stop_browser_recording, fn %Task{} -> nil end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    assert %Run{error: nil} = demo_run_finished(run, [])
  end

  test "a run that never started a take says so", %{task: task, run: run} do
    expect(Tools, :stop_browser_recording, fn %Task{} -> nil end)

    assert %Run{error: "The demo agent never called demo_start, so nothing was recorded."} =
             demo_run_finished(run, [])

    assert %Task{stage: :demo} = Repo.reload!(task)
  end

  test "a browser that painted nothing is not a video", %{run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:error, :nothing_recorded} end)

    assert %Run{error: "The browser painted no frames, so there is nothing to watch."} = demo_run_finished(run, [])
  end

  # Not the agent's fault at all, and still the reason there is nothing to watch.
  test "a machine with no ffmpeg says that rather than blaming the recording", %{run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:error, :no_ffmpeg} end)

    assert %Run{error: "The recording could not be encoded: ffmpeg is not installed on this machine."} =
             demo_run_finished(run, [])
  end

  test "an encode that failed says what ffmpeg said", %{run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)

    expect(Tools, :encode_recording, fn ^demo_dir, [] ->
      {:error, {:encode_failed, "frames/000000.jpg: Invalid data"}}
    end)

    assert %Run{error: error} = demo_run_finished(run, [])
    assert error =~ "ffmpeg said: frames/000000.jpg: Invalid data"
  end

  test "a run that filmed and wrote nothing up leaves the stage open", %{task: task, run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    expect(Tools, :stop_browser_recording, fn %Task{} -> demo_dir end)
    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    assert %Run{error: "The demo agent did not write demo/DFN-1.json."} = demo_run_finished(run, [])
    assert %Task{stage: :demo} = Repo.reload!(task)
  end
end
