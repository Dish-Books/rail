defmodule Rail.Repo.Migrations.EmptyNullFindingPlaceSteps do
  use Ecto.Migration

  # A place saved with null steps loads as nil and crashes the finding page and Send, so those read as none.
  def up do
    execute """
    UPDATE findings
    SET places = (
      SELECT jsonb_agg(
        CASE WHEN place->'steps' = 'null'::jsonb THEN jsonb_set(place, '{steps}', '[]'::jsonb) ELSE place END
        ORDER BY position
      )
      FROM jsonb_array_elements(places) WITH ORDINALITY AS list(place, position)
    )
    WHERE places @> '[{"steps": null}]'
    """
  end

  # A null and `[]` read the same to a person, so there is nothing to put back.
  def down, do: :ok
end
