defmodule Rail.Pipeline.Workers.CheckPreviewsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Preview
  alias Rail.Pipeline.Workers.CheckPreviews
  alias Rail.Projects

  # Each task's worktree was never made, so each preview checked is found gone without asking any deployment.
  test "looks at the preview of each task with a pull request at Review or Finalize, in a project that shows them", %{
    project: project
  } do
    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{
        preview_enabled: true,
        preview_url_template: "https://pr-{pr_number}.preview.example.com"
      })

    tasks =
      Map.new(
        [review: "CPW-1", finalize: "CPW-2", engineer: "CPW-3", merged: "CPW-4", no_pr: "CPW-5", cleaned: "CPW-6"],
        fn {key, identifier} ->
          stage = if key in [:no_pr, :cleaned], do: :review, else: key
          task = learnings_task(project, identifier, stage)
          on_exit(fn -> File.rm_rf(task.scratch_path) end)

          attrs =
            case key do
              :no_pr -> %{}
              :cleaned -> %{pr_number: 6, cleaned_up_at: DateTime.utc_now()}
              _checked -> %{pr_number: System.unique_integer([:positive])}
            end

          {:ok, task} = Pipeline.update_task(task, attrs)
          {key, task}
        end
      )

    assert :ok = perform_job(CheckPreviews, %{})

    assert %Preview{status: :gone} = Pipeline.get_preview(tasks.review)
    assert %Preview{status: :gone} = Pipeline.get_preview(tasks.finalize)

    for key <- [:engineer, :merged, :no_pr, :cleaned], do: assert(Pipeline.get_preview(tasks[key]) == nil)

    # A project that stops showing previews has none looked at, whatever its tasks.
    {:ok, _off} = Projects.update_project(system_scope(), tasks.review.project, %{preview_enabled: false})
    Repo.delete!(Pipeline.get_preview(tasks.review))

    assert :ok = perform_job(CheckPreviews, %{})
    assert Pipeline.get_preview(tasks.review) == nil
  end
end
