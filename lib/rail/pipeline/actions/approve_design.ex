defmodule Rail.Pipeline.Actions.ApproveDesign do
  @moduledoc """
  Publishes the design the human picked and refined, and hands the task to the
  architect.

  The picked option's screenshot is uploaded to Linear and added to the bottom of
  the issue's description, so the ticket carries the design everyone agreed on.
  The screenshot is the published thing, so one older than its page is refused:
  it would publish a design nobody approved.

  Approving is a one-way door: the task leaves design, and a task no longer there
  has nothing left to approve.
  """

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Approves the option picked from the design `run` produced and enters architect.

  Returns `{:ok, run}`, the run that was handed in, latched done.
  """
  def approve_design(%Run{} = run) do
    run = Repo.preload(run, [task: [:issue, :runs, project: :linear_workspace]], force: true)

    with :ok <- approvable(run.task),
         {:ok, option} <- picked_option(run.task),
         {:ok, screenshot} <- screenshot(option),
         :ok <- publish(run.task, option, screenshot) do
      enter_next(run)
    end
  end

  defp approvable(%Task{stage: stage}) when stage != :design, do: {:error, {:invalid_stage, stage}}

  defp approvable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  defp picked_option(%Task{} = task) do
    case Pipeline.read_design(task) do
      %{picked: key, options: options} when is_binary(key) -> {:ok, Enum.find(options, &(&1.key == key))}
      _no_pick -> {:error, :nothing_picked}
    end
  end

  defp screenshot(option) do
    with {:ok, %File.Stat{mtime: html_mtime}} <- File.stat(option.html_path, time: :posix),
         {:ok, %File.Stat{mtime: screenshot_mtime}} <- File.stat(option.screenshot_path, time: :posix) do
      if screenshot_mtime >= html_mtime,
        do: {:ok, File.read!(option.screenshot_path)},
        else: {:error, :stale_screenshot}
    else
      {:error, _missing} -> {:error, :screenshot_missing}
    end
  end

  # Linear hears about the description from the sync the issue write enqueues.
  defp publish(%Task{issue: %Issue{} = issue} = task, option, screenshot) do
    with {:ok, asset_url} <-
           Issues.upload_asset(task.project, "#{issue.identifier}-#{option.key}.png", "image/png", screenshot),
         {:ok, _issue} <- Issues.update_issue(issue, %{description: description(issue, option, asset_url)}) do
      :ok
    end
  end

  defp description(%Issue{description: description}, option, asset_url) do
    section = String.trim("## Design: #{option.title}\n\n#{option.summary}") <> "\n\n![#{option.title}](#{asset_url})"

    case String.trim(description || "") do
      "" -> section
      existing -> existing <> "\n\n" <> section
    end
  end

  defp enter_next(%Run{} = run) do
    {:ok, run} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
    {:ok, _next} = Pipeline.enter_stage(run.task, :architect)

    {:ok, run}
  end
end
