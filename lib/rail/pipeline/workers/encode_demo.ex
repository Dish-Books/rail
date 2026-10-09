defmodule Rail.Pipeline.Workers.EncodeDemo do
  @moduledoc """
  Encodes the take the demo recorder just saved, and publishes it as the video on the issue and the pull
  request. One job per task while one is queued or running, so a write-up saved twice encodes once.

  The encode squeezes out the time nothing happened and ends once the last caption has been read, so the
  captions go in with their reading times and come back as where they landed in the video, written beside
  the moment each was said. What goes wrong is said in the Review lead's conversation, where the human
  reads the run, since a demo that did not encode is not a reason to fail the review.
  """
  use Oban.Worker,
    queue: :issues,
    # A second attempt is what Oban's lifeline rescues an encode a deploy cut off into.
    max_attempts: 2,
    unique: [keys: [:task_id], states: [:available, :scheduled, :executing, :retryable], period: :infinity]

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
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> encode(Repo.preload(task, :issue))
      nil -> :ok
    end
  end

  defp encode(%Task{} = task) do
    directory = Path.join(task.scratch_path, "demo")

    if File.dir?(Path.join(directory, "frames")) do
      encoded(task, directory)
    else
      say(task, "The demo recorder never called demo_start, so nothing was recorded.")
    end

    Pipeline.broadcast_output_saved(task)
    :ok
  end

  defp encoded(%Task{} = task, directory) do
    beats = Pipeline.list_demo_beats(task)
    marks = Enum.map(beats, &{&1.recorded_ms, DemoBeat.reading_ms(&1)})

    case Tools.encode_recording(directory, marks) do
      {:ok, _video, video_times} ->
        timed(directory, beats, video_times)
        published(task)

      {:error, :nothing_recorded} ->
        say(task, "The browser painted no frames, so there is no demo to watch.")

      {:error, :no_ffmpeg} ->
        say(task, "The demo could not be encoded: ffmpeg is not installed on this machine.")

      {:error, {:encode_failed, output}} ->
        say(task, "The demo could not be encoded. ffmpeg said: #{tail(output)}")
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

  defp published(%Task{} = task) do
    case Pipeline.read_demo(task) do
      %Demo{} = demo -> publish(task, demo)
      nil -> say(task, "The demo recorder did not save a write-up, so the demo was not published.")
    end
  end

  # Linear keeps the video, since the scratch directory goes when the task is
  # cleaned up; the pull request links to it for whoever reviews it there.
  defp publish(%Task{issue: %Issue{} = issue} = task, %Demo{} = demo) do
    %Project{} = project = Repo.get!(Project, task.project_id)

    with {:ok, video} <- File.read(Path.join([task.scratch_path, "demo", "demo.webm"])),
         {:ok, asset_url} <- Issues.upload_asset(project, "#{issue.identifier}-demo.webm", "video/webm", video),
         {:ok, _comment} <- Issues.comment(Scope.for_system(), issue, %{body: comment(demo, asset_url)}),
         :ok <- link_from_pull_request(project, task, asset_url) do
      :ok
    else
      {:error, reason} -> say(task, "Could not publish the demo: #{inspect(reason)}")
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

  # One line, since a log line that wraps reads its tail as the agent's words.
  defp say(%Task{} = task, text) do
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: task.project_id, stage: :review_lead)

    case Repo.get_by(Run, task_id: task.id, role_id: role_id) do
      %Run{id: run_id} ->
        Pipeline.append_run_events(run_id, nil, ["[rail] " <> (text |> String.split() |> Enum.join(" "))])

      nil ->
        :ok
    end
  end
end
