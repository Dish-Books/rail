defmodule Rail.Issues.Actions.RemoveTestingImage do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Takes the picture at `url` out of the testing notes of a ticket in the testing queue, and returns the ticket as it
  now reads. The tracker keeps the file; nothing links to it any more. Refuses with `:testing_finished` once the
  ticket is out of the queue.
  """
  def remove_testing_image(%Scope{} = scope, %Issue{id: id, project_id: project_id}, url) when is_binary(url) do
    with true <- Scope.can_access_project?(scope, project_id) || {:error, :not_found},
         {:ok, saved} <-
           Repo.transaction(fn ->
             locked =
               Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE"))

             cond do
               is_nil(locked) ->
                 Repo.rollback(:not_found)

               not Issue.in_testing_queue?(locked) ->
                 Repo.rollback(:testing_finished)

               true ->
                 kept = Enum.reject(locked.testing_images, &(&1.url == url))
                 locked |> Issue.testing_images_changeset(kept) |> Repo.update!()
             end
           end) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "testing", {:testing_notes_changed, id})
      {:ok, saved}
    end
  end
end
