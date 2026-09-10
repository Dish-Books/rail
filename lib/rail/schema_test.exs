defmodule Rail.SchemaTest do
  use Rail.DataCase, async: false

  alias Rail.SchemaTest.Child
  alias Rail.SchemaTest.EmbeddedChild
  alias Rail.SchemaTest.Parent

  @moduletag :shared_sandbox

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
      belongs_to :parent, Parent, type: UXID
      timestamps()
    end

    def changeset(child, attrs, project_id \\ nil) do
      child
      |> cast(attrs, [:project_id, :parent_id])
      |> validate_relationships([:parent], project_id)
    end
  end

  defmodule EmbeddedChild do
    @moduledoc false
    use Rail.Schema

    @primary_key false
    embedded_schema do
      field :project_id, UXID
      belongs_to :parent, Parent, type: UXID
    end

    def changeset(child, attrs, project_id \\ nil) do
      child
      |> cast(attrs, [:project_id, :parent_id])
      |> validate_relationships([:parent], project_id)
    end
  end

  setup_all do
    Rail.Repo.query!("""
    CREATE TABLE IF NOT EXISTS schema_test_parents (
      id text PRIMARY KEY,
      project_id text,
      name text,
      inserted_at timestamp(6) not null,
      updated_at timestamp(6) not null
    )
    """)

    Rail.Repo.query!("""
    CREATE TABLE IF NOT EXISTS schema_test_children (
      id text PRIMARY KEY,
      project_id text,
      parent_id text REFERENCES schema_test_parents(id),
      inserted_at timestamp(6) not null,
      updated_at timestamp(6) not null
    )
    """)

    :ok
  end

  test "schema defaults: UXID primary key, UXID foreign key, utc_datetime_usec timestamps" do
    assert Parent.__schema__(:primary_key) == [:id]
    assert {:parameterized, {UXID, _params}} = Parent.__schema__(:type, :id)
    assert {:parameterized, {UXID, _params}} = Child.__schema__(:type, :parent_id)
    assert Parent.__schema__(:type, :inserted_at) == :utc_datetime_usec
    assert Parent.__schema__(:type, :updated_at) == :utc_datetime_usec
  end

  test "validate_relationships does nothing when owner key is not changed" do
    changeset = Child.changeset(%Child{}, %{})
    assert changeset.valid?
  end

  test "validate_relationships does nothing when relationship id is not binary" do
    changeset = Child.changeset(%Child{}, %{parent_id: nil})
    assert changeset.valid?
  end

  test "validate_relationships raises ArgumentError when project_id is missing" do
    assert_raise ArgumentError, ~r/validate_relationships\/3 needs a project_id/, fn ->
      changeset = Child.changeset(%Child{}, %{parent_id: "prj_123"})
      Rail.Repo.insert(changeset)
    end
  end

  test "validate_relationships adds error on embedded schema when relation does not exist" do
    changeset = EmbeddedChild.changeset(%EmbeddedChild{}, %{parent_id: "nonexistent"}, "prj_123")
    assert errors_on(changeset).parent_id == ["does not exist"]
  end

  test "validate_relationships adds error when relation does not exist" do
    changeset = Child.changeset(%Child{}, %{project_id: "prj_123", parent_id: "nonexistent"})
    assert {:error, changeset} = Rail.Repo.insert(changeset)
    assert errors_on(changeset).parent_id == ["does not exist"]
  end

  test "validate_relationships succeeds when related record exists for the same project" do
    parent_id = UXID.generate!(prefix: "prj")
    now = DateTime.utc_now()

    Rail.Repo.query!(
      "INSERT INTO schema_test_parents (id, project_id, name, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5)",
      [parent_id, "prj_test", "Parent", now, now]
    )

    changeset = Child.changeset(%Child{}, %{project_id: "prj_test", parent_id: parent_id})
    assert {:ok, _child} = Rail.Repo.insert(changeset)
  end
end
