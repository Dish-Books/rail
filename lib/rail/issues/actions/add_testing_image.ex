defmodule Rail.Issues.Actions.AddTestingImage do
  @moduledoc false

  import Ecto.Query

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
  Stores a picture through the ticket's tracker and adds it to the testing notes of a ticket in the testing queue,
  returning the ticket as it now reads. Broadcasts as `Rail.Issues.save_testing_notes/3` does. Refuses with
  `:not_accepted` for a name that is not a PNG, JPEG, GIF or WebP, `:unsupported` from a tracker that holds no files,
  and `:testing_finished` once the ticket is out of the queue.
  """
  def add_testing_image(%Scope{} = scope, %Issue{id: id, project_id: project_id} = issue, filename, data)
      when is_binary(filename) and is_binary(data) do
    content_type = @types[filename |> Path.extname() |> String.downcase()]
    issue = Repo.preload(issue, :project)

    # The upload is outside the lock, so a slow tracker never holds other testers' saves.
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         true <- is_binary(content_type) || {:error, :not_accepted},
         true <- Issue.in_testing_queue?(issue) || {:error, :testing_finished},
         {:ok, url} <- Tracker.tracker(issue).upload_asset(issue, filename, content_type, data),
         {:ok, {was, saved}} <-
           Repo.transaction(fn -> append(id, project_id, %TestingImage{url: url, name: filename}) end) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "testing", {:testing_notes_changed, id})

      if was.testing_state != saved.testing_state,
        do: Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})

      {:ok, saved}
    end
  end

  defp append(id, project_id, image) do
    locked = Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE"))

    cond do
      is_nil(locked) ->
        Repo.rollback(:not_found)

      not Issue.in_testing_queue?(locked) ->
        Repo.rollback(:testing_finished)

      true ->
        {locked,
         locked |> Issue.testing_images_changeset(List.insert_at(locked.testing_images, -1, image)) |> Repo.update!()}
    end
  end
end
