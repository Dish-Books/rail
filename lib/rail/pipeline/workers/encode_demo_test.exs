defmodule Rail.Pipeline.Workers.EncodeDemoTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Workers.EncodeDemo
  alias Rail.Roles
  alias Rail.Tools

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_edm_1", "identifier" => "EDM-1", "title" => "Encode Demo"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Encode Demo"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(demo_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_encode_demo",
        started_at: DateTime.utc_now()
      })

    %{task: task, run: run, demo_dir: demo_dir}
  end

  # The encode squeezes out the time nothing happened, so where a caption plays is
  # no longer where it was said. Both are kept: the player wants the first, and
  # the next encode wants the second.
  test "each caption learns where it plays in the video, and keeps where it was said", %{
    task: task,
    demo_dir: demo_dir
  } do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    File.write!(Path.join(demo_dir, "captions.jsonl"), """
    {"at_ms": 0, "text": "Starting on the bills page", "criterion": null}
    {"at_ms": 95000, "text": "Saved exactly as entered", "criterion": "A bill saves"}
    """)

    # Each caption goes in with its reading time, four words a second.
    expect(Tools, :encode_recording, fn ^demo_dir, [{0, 1_250}, {95_000, 1_200}] ->
      {:ok, Path.join(demo_dir, "demo.webm"), [0, 31_000]}
    end)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})

    assert [
             %DemoBeat{at_ms: 0, recorded_ms: 0, text: "Starting on the bills page"},
             %DemoBeat{at_ms: 31_000, recorded_ms: 95_000, criterion: "A bill saves"}
           ] = Pipeline.list_demo_beats(task)
  end

  test "a recorded demo is posted on the ticket and linked from the pull request", %{
    task: task,
    run: run,
    demo_dir: demo_dir
  } do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 7, pr_is_draft: true})
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "EDM-1.json"), ~s({"title": "Filters", "summary": "It filters."}))
    File.write!(Path.join(demo_dir, "demo.webm"), "webm bytes")

    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "fileUpload" => %{
            "success" => true,
            "uploadFile" => %{
              "uploadUrl" => "https://uploads.linear.app/put/edm-1",
              "assetUrl" => "https://uploads.linear.app/assets/EDM-1-demo.webm",
              "headers" => []
            }
          }
        }
      })
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      assert {:ok, "webm bytes", conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      comment = "## Demo: Filters\n\nIt filters.\n\n[Watch the demo](https://uploads.linear.app/assets/EDM-1-demo.webm)"
      assert %{"variables" => %{"input" => %{"body" => ^comment}}} = Jason.decode!(body)

      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "comment_demo",
              "body" => comment,
              "createdAt" => "2026-09-22T10:00:00.000Z",
              "issue" => %{"id" => "lin_edm_1"},
              "botActor" => %{"name" => "Rail"}
            }
          }
        }
      })
    end)

    # A re-recorded demo replaces the link rather than adding another under it.
    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls/7"} ->
          Req.Test.json(conn, %{"number" => 7, "body" => "Opened by Rail.\n\n## Demo\n\n[Watch the demo](old)"})

        {"PATCH", "/repos/example/test-seed/pulls/7"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert %{
                   "body" =>
                     "Opened by Rail.\n\n## Demo\n\n[Watch the demo](https://uploads.linear.app/assets/EDM-1-demo.webm)"
                 } = Jason.decode!(body)

          Req.Test.json(conn, %{"number" => 7})
      end
    end)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})
    assert [] = Pipeline.list_run_events(run)
  end

  test "a recorded demo on a task with no pull request goes on the ticket alone", %{
    task: task,
    run: run,
    demo_dir: demo_dir
  } do
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "EDM-1.json"), ~s({"title": "Filters", "summary": "It filters."}))
    File.write!(Path.join(demo_dir, "demo.webm"), "webm bytes")

    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "fileUpload" => %{
            "success" => true,
            "uploadFile" => %{
              "uploadUrl" => "https://uploads.linear.app/put/edm-1",
              "assetUrl" => "https://uploads.linear.app/a.webm",
              "headers" => []
            }
          }
        }
      })
    end)

    Req.Test.expect(Rail.Linear, &Plug.Conn.send_resp(&1, 200, ""))

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "commentCreate" => %{
            "success" => true,
            "comment" => %{
              "id" => "comment_demo_2",
              "body" => "## Demo: Filters",
              "createdAt" => "2026-09-22T10:00:00.000Z",
              "issue" => %{"id" => "lin_edm_1"},
              "botActor" => %{"name" => "Rail"}
            }
          }
        }
      })
    end)

    Req.Test.stub(Client, fn _conn -> flunk("asked GitHub about a pull request the task does not have") end)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})
    assert [] = Pipeline.list_run_events(run)
  end

  # A demo is not a reason to fail the review, so what went wrong is said where the human reads the run.
  test "a demo that could not be published says so on the Review lead's run", %{
    task: task,
    run: run,
    demo_dir: demo_dir
  } do
    File.mkdir_p!(Path.join(demo_dir, "frames"))
    File.write!(Path.join(demo_dir, "EDM-1.json"), ~s({"title": "Filters", "summary": "It filters."}))
    File.write!(Path.join(demo_dir, "demo.webm"), "webm bytes")

    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)
    Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"fileUpload" => %{"success" => false}}}))

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})
    assert [%{line: "[rail] Could not publish the demo: " <> _reason}] = Pipeline.list_run_events(run)
  end

  test "a take never started says so", %{task: task, run: run} do
    reject(&Tools.encode_recording/2)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})

    assert [%{line: "[rail] The demo recorder never called demo_start, so nothing was recorded."}] =
             Pipeline.list_run_events(run)
  end

  test "a browser that painted nothing is not a video", %{task: task, run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:error, :nothing_recorded} end)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})

    assert [%{line: "[rail] The browser painted no frames, so there is no demo to watch."}] =
             Pipeline.list_run_events(run)
  end

  # Not the recorder's fault at all, and still the reason there is nothing to watch.
  test "a machine with no ffmpeg says that rather than blaming the recording", %{
    task: task,
    run: run,
    demo_dir: demo_dir
  } do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:error, :no_ffmpeg} end)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})

    assert [%{line: "[rail] The demo could not be encoded: ffmpeg is not installed on this machine."}] =
             Pipeline.list_run_events(run)
  end

  # One line, since a log line that wraps reads its tail as the agent's words.
  test "an encode that failed says what ffmpeg said, on one line", %{task: task, run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    expect(Tools, :encode_recording, fn ^demo_dir, [] ->
      {:error, {:encode_failed, "frames/000000.jpg:\nInvalid data"}}
    end)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})

    assert [%{line: "[rail] The demo could not be encoded. ffmpeg said: frames/000000.jpg: Invalid data"}] =
             Pipeline.list_run_events(run)
  end

  test "a take with no write-up is encoded and not published", %{task: task, run: run, demo_dir: demo_dir} do
    File.mkdir_p!(Path.join(demo_dir, "frames"))

    expect(Tools, :encode_recording, fn ^demo_dir, [] -> {:ok, Path.join(demo_dir, "demo.webm"), []} end)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})

    assert [%{line: "[rail] The demo recorder did not save a write-up, so the demo was not published."}] =
             Pipeline.list_run_events(run)
  end

  test "whatever came of it, the task's outputs are told to read again", %{task: %{id: task_id}} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

    assert :ok = perform_job(EncodeDemo, %{task_id: task_id})
    assert_received {:output_saved, ^task_id}
  end

  # The Review lead's run is where a problem is said, and a task can lose it to Retry before the job runs.
  test "a task with no Review lead run has nowhere to say what went wrong", %{task: task, run: run} do
    Repo.delete!(run)

    assert :ok = perform_job(EncodeDemo, %{task_id: task.id})
  end

  # A deploy that cuts an encode off leaves it executing; Oban's lifeline rescues it only into an attempt left.
  test "an encode cut off once is tried a second time", %{task: %{id: task_id}} do
    assert %{max_attempts: 2} = EncodeDemo.new(%{task_id: task_id}).changes
  end

  test "a task gone before its encode ran has nothing to encode" do
    reject(&Tools.encode_recording/2)

    assert :ok = perform_job(EncodeDemo, %{task_id: "tsk_gone"})
  end
end
