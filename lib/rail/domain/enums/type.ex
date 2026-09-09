defmodule Rail.Domain.Enums.Type do
  @moduledoc """
  Reusable macro providing `Ecto.Type` and helper functions for domain enums.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Ecto.Type

      @values Keyword.fetch!(opts, :values)
      @labels Keyword.get(opts, :labels, %{})

      @doc "Returns all allowed atom values for this enum."
      def all, do: @values

      @doc "Alias for all/0."
      def values, do: @values

      @doc "Returns true if the given value is a valid enum atom or representation."
      def valid?(value) when is_atom(value), do: value in @values

      def valid?(value) when is_binary(value) do
        case cast(value) do
          {:ok, _atom} -> true
          :error -> false
        end
      end

      def valid?(_other), do: false

      @doc "Returns the human-readable display label for the given enum value."
      def label(nil), do: nil

      def label(value) when is_atom(value) do
        case Map.fetch(@labels, value) do
          {:ok, label} ->
            label

          :error ->
            if value in @values do
              value
              |> Atom.to_string()
              |> String.replace("_", " ")
              |> String.capitalize()
            end
        end
      end

      def label(value) when is_binary(value) do
        case cast(value) do
          {:ok, atom} -> label(atom)
          :error -> nil
        end
      end

      def label(_other), do: nil

      @impl Ecto.Type
      def type, do: :string

      @impl Ecto.Type
      def cast(nil), do: {:ok, nil}

      def cast(value) when is_atom(value) do
        if value in @values do
          {:ok, value}
        else
          :error
        end
      end

      def cast(value) when is_binary(value) do
        normalized =
          value
          |> String.trim()
          |> Macro.underscore()
          |> String.replace("-", "_")

        Enum.find_value(@values, :error, fn val ->
          if Atom.to_string(val) == normalized do
            {:ok, val}
          end
        end)
      end

      def cast(_other), do: :error

      @impl Ecto.Type
      def dump(nil), do: {:ok, nil}

      def dump(value) when is_atom(value) do
        if value in @values do
          {:ok, Atom.to_string(value)}
        else
          :error
        end
      end

      def dump(value) when is_binary(value) do
        case cast(value) do
          {:ok, atom} -> {:ok, Atom.to_string(atom)}
          :error -> :error
        end
      end

      def dump(_other), do: :error

      @impl Ecto.Type
      def load(nil), do: {:ok, nil}

      def load(value) when is_binary(value) do
        case cast(value) do
          {:ok, atom} -> {:ok, atom}
          :error -> :error
        end
      end

      def load(value) when is_atom(value) do
        if value in @values do
          {:ok, value}
        else
          :error
        end
      end

      def load(_other), do: :error

      @impl Ecto.Type
      def embed_as(_format), do: :self

      @impl Ecto.Type
      def equal?(a, b), do: a == b
    end
  end
end
