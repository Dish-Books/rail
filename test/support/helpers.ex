defmodule RailTest.Helpers do
  @moduledoc false

  alias Rail.Scope

  defdelegate user_scope(attrs \\ []), to: Scope
  defdelegate temp_user_scope(attrs \\ []), to: Scope
  defdelegate system_scope, to: Scope
end
