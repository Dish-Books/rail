defmodule Rail.Schema do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      import Ecto.Changeset
      import Ecto.Query

      @primary_key {:id, UXID, autogenerate: true}
      @foreign_key_type UXID
      @timestamps_opts [type: :utc_datetime_usec]

      def validate_relationships(changeset, fields, project_id \\ nil) do
        Enum.reduce(fields, changeset, fn relationship, changeset ->
          case changeset.data do
            %{__meta__: _meta} ->
              prepare_changes(changeset, &validate_relationship(&1, relationship, project_id))

            _embedded ->
              validate_relationship(changeset, relationship, project_id)
          end
        end)
      end

      def validate_relationship(changeset, relationship, project_id) do
        association = changeset.data.__struct__.__schema__(:association, relationship)

        relationship_id = get_field(changeset, association.owner_key)
        project_id = get_field(changeset, :project_id) || project_id

        if changed?(changeset, association.owner_key) and is_binary(relationship_id) do
          is_binary(project_id) ||
            raise ArgumentError, "validate_relationships/3 needs a project_id to check #{relationship}"

          if Rail.Repo.exists?(
               from r in association.queryable,
                 where: r.project_id == ^project_id and r.id == ^relationship_id
             ) do
            changeset
          else
            add_error(changeset, association.owner_key, "does not exist")
          end
        else
          changeset
        end
      end
    end
  end
end
