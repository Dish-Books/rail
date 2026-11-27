defmodule Rail.Issues.Actions.AddTestingImage do
  @moduledoc false

  import Rail.Issues.Utils.UpdateTesting

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.TestingImage
  alias Rail.Issues.Tracker
  alias Rail.Repo
  alias Rail.Scope

  # The type comes from the name, never from the browser, so nothing is stored as anything but a picture.
  @types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @doc """
  Stores a picture and adds it to the scenario `scenario_id` of a ticket in the testing queue, returning the ticket as
  it now reads. Refuses with `:not_accepted` for a name that is not a PNG, JPEG, GIF or WebP, `:not_found` for a
  scenario the ticket no longer has, and as `Rail.Issues.Utils.UpdateTesting` does.
  """
  def add_testing_image(%Scope{} = scope, %Issue{project_id: project_id} = issue, scenario_id, filename, data)
      when is_binary(scenario_id) and is_binary(filename) and is_binary(data) do
    content_type = @types[filename |> Path.extname() |> String.downcase()]
    issue = Repo.preload(issue, :project)

    # The upload is outside the lock, so a slow tracker never holds other testers' saves.
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         true <- is_binary(content_type) || {:error, :not_accepted},
         true <- Issue.in_testing_queue?(issue) || {:error, :testing_finished},
         # Read again under the lock below; checked here so a refused picture is never uploaded.
         false <- Issue.writing_scenarios?(issue) && {:error, :writing_scenarios},
         {:ok, url} <- Tracker.upload_asset(issue, filename, content_type, data) do
      image = %TestingImage{url: url, name: filename}

      update_testing(scope, issue, fn locked ->
        case Enum.find_index(locked.testing_scenarios, &(&1.id == scenario_id)) do
          index when is_integer(index) ->
            scenarios =
              List.update_at(locked.testing_scenarios, index, &%{&1 | images: List.insert_at(&1.images, -1, image)})

            Issue.testing_scenarios_changeset(locked, scenarios, :tester)

          nil ->
            {:error, :not_found}
        end
      end)
    end
  end
end
