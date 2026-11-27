defmodule Rail.Issues.Schemas.TestingImage do
  @moduledoc """
  A picture a tester added to a failed scenario, or beside notes from before scenarios: stored by the ticket's tracker
  at `url`, under the name it was added with.
  """
  use Rail.Schema

  @primary_key false
  embedded_schema do
    field :url, :string
    field :name, :string
  end
end
