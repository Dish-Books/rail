defmodule Rail.Schema do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      import Ecto.Changeset
      import Ecto.Query

      @primary_key {:id, UXID, autogenerate: true}
      @foreign_key_type UXID
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
