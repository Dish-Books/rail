defmodule Rail.Backends.ModelOption do
  @moduledoc """
  Represents an AI model option available from a CLI backend.
  """

  @derive Jason.Encoder
  defstruct [:id, :display_name, :description]

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          description: String.t() | nil
        }
end
