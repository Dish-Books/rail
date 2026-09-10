defmodule RailTest.Mocks.ErrorConnAdapter do
  @moduledoc false

  def read_req_body(_state, _opts), do: {:error, :timeout}
end
