defmodule Rail.Projects.Schemas.EnvFileTest do
  use Rail.DataCase, async: true

  alias Rail.Projects.Schemas.EnvFile
  alias Rail.Projects.Schemas.EnvFile.Variable

  test "reads each variable a file sets, in order, and writes its value back as it was" do
    text = "# Comment\r\n\nexport API_KEY = sk_1=2\nQUOTED=\"two words\"\n  EMPTY=\nnot a variable\n"

    assert %EnvFile{
             variables: [
               %Variable{id: <<_id::binary-36>>, name: "API_KEY", value: " sk_1=2"},
               %Variable{name: "QUOTED", value: "\"two words\""},
               %Variable{name: "EMPTY", value: ""}
             ]
           } = env_file = EnvFile.from_text(text)

    assert EnvFile.to_text(env_file) == "API_KEY= sk_1=2\nQUOTED=\"two words\"\nEMPTY=\n"
  end

  test "an empty file has no variables" do
    assert %EnvFile{variables: []} = EnvFile.from_text("")
  end

  test "a name used twice is refused on its later row" do
    changeset =
      EnvFile.changeset(%EnvFile{}, %{
        "variables" => %{
          "0" => %{"name" => "FOO", "value" => "1"},
          "1" => %{"name" => "BAR", "value" => "2"},
          "2" => %{"name" => "FOO", "value" => "3"}
        }
      })

    refute changeset.valid?
    assert %{variables: [%{}, %{}, %{name: ["FOO is already set above"]}]} = errors_on(changeset)
  end

  test "a name that is blank or no variable name is refused, a trailing newline included" do
    changeset =
      EnvFile.changeset(%EnvFile{}, %{
        "variables" => %{
          "0" => %{"name" => "FOO\n", "value" => "1"},
          "1" => %{"name" => "1ST", "value" => "2"},
          "2" => %{"name" => " ", "value" => "3"}
        }
      })

    assert %{
             variables: [
               %{name: ["Use letters, digits and _, not starting with a digit"]},
               %{name: ["Use letters, digits and _, not starting with a digit"]},
               %{name: ["can't be blank"]}
             ]
           } = errors_on(changeset)
  end

  test "rows are added and removed through the sort and drop params, each keeping its id" do
    %EnvFile{variables: [%Variable{id: foo_id}, %Variable{id: bar_id}]} = env_file = EnvFile.from_text("FOO=1\nBAR=2\n")

    changeset =
      EnvFile.changeset(env_file, %{
        "variables" => %{
          "0" => %{"id" => foo_id, "name" => "FOO", "value" => "1"},
          "1" => %{"id" => bar_id, "name" => "BAR", "value" => "2"}
        },
        "variables_sort" => ["0", "1", "new"],
        "variables_drop" => ["0"]
      })

    assert [%Variable{id: ^bar_id, name: "BAR"}, %Variable{id: <<_id::binary-36>> = new_id, name: nil, value: ""}] =
             get_field(changeset, :variables)

    assert {:ok, %EnvFile{variables: [%Variable{id: ^new_id, name: "NEW"}]}} =
             env_file
             |> EnvFile.changeset(%{
               "variables" => %{"0" => %{"id" => new_id, "name" => "NEW", "value" => ""}},
               "variables_drop" => [""]
             })
             |> Ecto.Changeset.apply_action(:save)
  end

  test "dropping every row leaves none" do
    assert {:ok, %EnvFile{variables: []}} =
             "FOO=1\n" |> EnvFile.from_text() |> EnvFile.changeset(%{"variables_drop" => [""]}) |> apply_action(:save)
  end
end
