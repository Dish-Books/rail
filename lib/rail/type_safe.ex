defmodule Rail.TypeSafe do
  @moduledoc """
  Context for TypeSafe, which answers typed questions about a state.

  Rail asks it what to do to a page: which operation, and which of the elements
  it just observed to do it to. It is not a text model and never writes anything
  - every answer is a choice out of a set Rail offered, which is what keeps model
  output from becoming a selector.
  """

  alias Rail.TypeSafe.Client

  defdelegate ask(state, questions, opts \\ []), to: Client
end
