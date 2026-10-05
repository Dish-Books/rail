defmodule Rail.Tools.Actions.ListModelsTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "lists each CLI's model once with every account offering it, in the order they were added" do
    scope = system_scope()

    {:ok, %Backend{id: work_id}} =
      Tools.create_backend(scope, %{
        name: :claude,
        label: "work",
        executable_path: "/usr/bin/true",
        models: [%{id: "claude-sonnet-5"}, %{id: "claude-fable-5-1"}]
      })

    {:ok, %Backend{id: max_id}} =
      Tools.create_backend(scope, %{
        name: :claude,
        label: "max-2",
        executable_path: "/usr/bin/true",
        models: [%{id: "claude-sonnet-5"}]
      })

    {:ok, %Backend{id: agy_id}} =
      Tools.create_backend(scope, %{name: :agy, executable_path: "/usr/bin/agy", models: [%{id: "claude-sonnet-5"}]})

    models = Enum.reject(Tools.list_models(), &(&1.id == "claude-opus-5-5"))

    assert [
             %{cli: :claude, id: "claude-sonnet-5", backends: [%Backend{id: ^work_id}, %Backend{id: ^max_id}]},
             %{
               cli: :claude,
               id: "claude-fable-5-1",
               display_name: "claude-fable-5-1",
               backends: [%Backend{id: ^work_id}]
             },
             %{cli: :agy, id: "claude-sonnet-5", backends: [%Backend{id: ^agy_id}]}
           ] = models
  end
end
