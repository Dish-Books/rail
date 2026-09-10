defmodule Rail.SchemaTest do
  use ExUnit.Case, async: true

  alias Rail.SchemaTest.Child
  alias Rail.SchemaTest.Parent

  defmodule Parent do
    @moduledoc false
    use Rail.Schema

    schema "schema_test_parents" do
      field :project_id, UXID
      field :name, :string
      timestamps()
    end
  end

  defmodule Child do
    @moduledoc false
    use Rail.Schema

    schema "schema_test_children" do
      field :project_id, UXID
      belongs_to :parent, Parent
      timestamps()
    end
  end

  test "schema defaults: UXID primary key, UXID foreign key, utc_datetime_usec timestamps" do
    assert [:id] = Parent.__schema__(:primary_key)
    assert {:parameterized, {UXID, _params}} = Parent.__schema__(:type, :id)
    assert {:parameterized, {UXID, _params}} = Child.__schema__(:type, :parent_id)
    assert :utc_datetime_usec = Parent.__schema__(:type, :inserted_at)
    assert :utc_datetime_usec = Parent.__schema__(:type, :updated_at)
  end
end
