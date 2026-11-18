defmodule Rail.Todos do
  @moduledoc """
  Each person's own to-do list in their own order: lines they type or links they drop, checked off to the
  bottom until their day ends, and the day's checked-off ones as a CSV. Nobody else sees them.
  """

  alias Rail.Todos.Actions

  defdelegate list_todos(scope, opts \\ []), to: Actions.ListTodos
  defdelegate create_todo(scope, attrs, place), to: Actions.CreateTodo
  defdelegate add_link_todo(scope, url, text, place), to: Actions.AddLinkTodo
  defdelegate move_todo(scope, todo, place), to: Actions.MoveTodo
  defdelegate complete_todo(scope, todo), to: Actions.CompleteTodo
  defdelegate reopen_todo(scope, todo), to: Actions.ReopenTodo
  defdelegate build_todos_csv(scope, time_zone, base_url), to: Actions.BuildTodosCsv
end
