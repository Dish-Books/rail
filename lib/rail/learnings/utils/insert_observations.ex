defmodule Rail.Learnings.Utils.InsertObservations do
  @moduledoc """
  Writes observations, skipping any whose source the project already recorded.
  """

  alias Rail.Learnings.Schemas.Observation
  alias Rail.Repo

  @fields [
    :task_id,
    :source_kind,
    :source_id,
    :source_url,
    :actor_id,
    :actor_name,
    :text,
    :excerpt,
    :abandoned,
    :learning_id
  ]

  @doc """
  Inserts one observation in `project_id` per attrs map, through its changeset,
  and returns only those that were new.
  """
  def insert_observations(_project_id, []), do: []

  def insert_observations(project_id, attrs_list) when is_binary(project_id) and is_list(attrs_list) do
    now = DateTime.utc_now()

    rows =
      Enum.map(attrs_list, fn attrs ->
        %Observation{project_id: project_id}
        |> Observation.changeset(attrs)
        |> Ecto.Changeset.apply_action!(:insert)
        |> Map.take(@fields)
        |> Map.merge(%{id: UXID.generate!(prefix: "obs"), project_id: project_id, inserted_at: now, updated_at: now})
      end)

    {_count, inserted} =
      Repo.insert_all(Observation, rows,
        on_conflict: :nothing,
        conflict_target: [:project_id, :source_kind, :source_id],
        returning: true
      )

    inserted
  end
end
