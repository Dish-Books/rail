defmodule RailWeb.ErrorJSONTest do
  use RailWeb.ConnCase, async: true

  defmodule SubItem do
    @moduledoc false
    use Ecto.Schema

    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :count, :integer
    end

    def changeset(item, attrs) do
      item
      |> cast(attrs, [:count])
      |> validate_required([:count])
    end
  end

  defmodule Item do
    @moduledoc false
    use Ecto.Schema

    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :name, :string
      embeds_many :sub_items, SubItem
      embeds_one :summary, SubItem
    end

    def changeset(item, attrs) do
      item
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> validate_length(:name, min: 3)
      |> cast_embed(:sub_items, with: &SubItem.changeset/2)
      |> cast_embed(:summary, with: &SubItem.changeset/2)
    end
  end

  test "renders 404.json" do
    assert RailWeb.ErrorJSON.render("404.json", %{}) == %{errors: [%{detail: "Not Found"}]}
  end

  test "renders 500.json" do
    assert RailWeb.ErrorJSON.render("500.json", %{}) == %{errors: [%{detail: "Internal Server Error"}]}
  end

  test "renders 422 unprocessable_entity flat and nested errors" do
    changeset = Item.changeset(%Item{}, %{"name" => "a", "sub_items" => [%{}], "summary" => %{}})

    result = RailWeb.ErrorJSON.render("unprocessable_entity.json", %{changeset: changeset})

    assert %{errors: errors} = result
    assert %{detail: "should be at least 3 character(s)", source: "name"} in errors
    assert %{detail: "can't be blank", source: "sub_items.0.count"} in errors
    assert %{detail: "can't be blank", source: "summary.count"} in errors
  end
end
