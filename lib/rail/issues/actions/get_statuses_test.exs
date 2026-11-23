defmodule Rail.Issues.Actions.GetStatusesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues

  test "a project offers Rail's statuses from Todo to Canceled, in the order an issue moves through them", %{
    project: project
  } do
    assert {:ok,
            [
              %{id: "todo", name: "Todo", state: :todo},
              %{id: "in_progress", name: "In Progress", state: :in_progress},
              %{id: "in_review", name: "In Review", state: :in_review},
              %{id: "done", name: "Done", state: :done},
              %{id: "canceled", name: "Canceled", state: :canceled}
            ]} = Issues.get_statuses(system_scope(), project)
  end

  test "a scope without the project is refused", %{project: project} do
    assert {:error, :not_found} = Issues.get_statuses(temp_user_scope(), project)
  end
end
