defmodule Rail.Tools.Actions.ListModelsTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "lists each CLI's model once with every account offering it, in the order they were added" do
    %Backend{id: work_id} = ready_backend(["claude-sonnet-5", "claude-fable-5-1"], [], %{label: "work"})
    %Backend{id: max_id} = ready_backend(["claude-sonnet-5"], [], %{label: "max-2", status: :signed_out})
    %Backend{id: agy_id} = ready_backend(["claude-sonnet-5"], [], %{name: :agy})

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
