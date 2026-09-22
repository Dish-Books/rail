defmodule Rail.Pipeline.Utils.DemoRunFinished do
  @moduledoc """
  Where a finished demo run leaves its task.

  At demo, with the video on the ticket and the pull request, and the pull
  request out of draft: the video is the last thing Rail makes, so it is done
  keeping people off it. A video that could not be published is said in the
  run's log rather than failing a demo that was recorded. The task stays because what
  happens next is the human's to say. They watch it and decide whether it shows
  what they asked for, and a walkthrough of the wrong thing is a message back
  rather than a state machine's problem.

  The encode squeezes out the time nothing happened, but never the time a caption
  needs to be read, so the captions go in as the stretches that must play at real
  speed and come back as where they landed in the video. That is written onto
  each caption, beside the moment it was said, so the player shows the words
  with the frame they describe.

  Three things a demo run can get wrong, and all three are recorded on the run so
  the stage stays open for the message that fixes it: exiting having never
  started a take, exiting having written no write-up, and a machine with no
  ffmpeg on it - which is not the agent's fault at all, but is still the reason
  there is no video to watch.

  The recording is stopped here rather than by the agent. A run that crashed, a
  run that was stopped and a run that finished cleanly all end up here, and all
  three should leave the frames they got. So does a run messaged again after it
  finished: the take it recorded is still on disk, and is encoded again from
  there.
  """

  import Rail.Pipeline.Utils.MarkPullRequestReady

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @doc "Finishes `run` as the demo stage."
  def demo_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)
    _stopped = Tools.stop_browser_recording(task)
    directory = Path.join(task.scratch_path, "demo")

    if File.dir?(Path.join(directory, "frames")) do
      encoded(run, task, directory)
    else
      fail(run, "The demo agent never called demo_start, so nothing was recorded.")
    end
  end

  defp encoded(%Run{} = run, %Task{} = task, directory) do
    beats = Pipeline.list_demo_beats(task)
    marks = Enum.map(beats, &{&1.recorded_ms, DemoBeat.reading_ms(&1)})

    case Tools.encode_recording(directory, marks) do
      {:ok, _video, video_times} ->
        timed(directory, beats, video_times)
        reported(run, task)

      {:error, :nothing_recorded} ->
        fail(run, "The browser painted no frames, so there is nothing to watch.")

      {:error, :no_ffmpeg} ->
        fail(run, "The recording could not be encoded: ffmpeg is not installed on this machine.")

      {:error, {:encode_failed, output}} ->
        fail(run, "The recording could not be encoded. ffmpeg said: #{tail(output)}")
    end
  end

  # The whole file every time, because it is a statement of the take rather than
  # a journal of it: the moment each caption was said is kept exactly as it was,
  # so the next encode starts from the recording's clock and not from this one's.
  defp timed(directory, beats, video_times) do
    lines =
      beats
      |> Enum.zip(video_times)
      |> Enum.map(fn {%DemoBeat{} = beat, video_ms} ->
        [
          Jason.encode_to_iodata!(%{
            at_ms: beat.recorded_ms,
            video_ms: video_ms,
            text: beat.text,
            criterion: beat.criterion
          }),
          "\n"
        ]
      end)

    File.write!(Path.join(directory, "captions.jsonl"), lines)
  end

  defp reported(%Run{} = run, %Task{} = task) do
    case Pipeline.read_demo(task) do
      %Demo{} = demo ->
        publish(run, task, demo)
        %{run | task: mark_pull_request_ready(task)}

      nil ->
        fail(run, "The demo agent did not write #{write_up(task)}.")
    end
  end

  # Linear keeps the video, since the scratch directory goes when the task is
  # cleaned up; the pull request links to it for whoever reviews it there.
  defp publish(%Run{} = run, %Task{issue: %Issue{} = issue} = task, %Demo{} = demo) do
    %Project{} = project = Repo.get!(Project, task.project_id)

    with {:ok, video} <- File.read(Path.join([task.scratch_path, "demo", "demo.webm"])),
         {:ok, asset_url} <- Issues.upload_asset(project, "#{issue.identifier}-demo.webm", "video/webm", video),
         {:ok, _comment} <- Issues.comment(Scope.for_system(), issue, %{body: comment(demo, asset_url)}),
         :ok <- link_from_pull_request(project, task, asset_url) do
      :ok
    else
      {:error, reason} ->
        Pipeline.append_run_events(run.id, nil, ["[rail] Could not publish the demo: #{inspect(reason)}"])
    end
  end

  defp comment(%Demo{title: title, summary: summary}, asset_url) do
    String.trim("## Demo: #{title}\n\n#{summary}") <> "\n\n[Watch the demo](#{asset_url})"
  end

  defp link_from_pull_request(%Project{}, %Task{pr_number: nil}, _asset_url), do: :ok

  defp link_from_pull_request(%Project{} = project, %Task{pr_number: number}, asset_url) do
    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, %{"body" => body}} <- GitHub.get_pull_request(token, project.github_repo, number),
         {:ok, _updated} <-
           GitHub.update_pull_request(token, project.github_repo, number, %{body: with_demo(body, asset_url)}) do
      :ok
    end
  end

  # A re-recorded demo replaces the link rather than adding another under it.
  defp with_demo(body, asset_url) do
    kept = (body || "") |> String.split("\n\n## Demo\n") |> List.first() |> String.trim_trailing()
    "#{kept}\n\n## Demo\n\n[Watch the demo](#{asset_url})"
  end

  # ffmpeg says what went wrong in its last few lines and spends everything above
  # them listing how it was built.
  defp tail(output), do: String.slice(output, -500, 500)

  defp write_up(%Task{issue: %Issue{identifier: identifier}}), do: "demo/#{identifier}.json"

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
