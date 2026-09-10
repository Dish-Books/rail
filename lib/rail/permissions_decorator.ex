defmodule Rail.PermissionsDecorator do
  @moduledoc false

  use Decorator.Define, can?: 1

  def can?(opts, body, context) do
    scope_arg = hd(context.args)

    quote do
      if unquote(permitted_ast(opts, scope_arg)) do
        unquote(body)
      else
        {:error, :not_authorized}
      end
    end
  end

  defp permitted_ast(opts, scope_arg) when is_atom(opts) do
    quote do
      Rail.Users.can?(var!(unquote(scope_arg)), unquote(opts))
    end
  end

  defp permitted_ast(opts, scope_arg) when is_list(opts) do
    case Keyword.fetch(opts, :any) do
      {:ok, requirements} ->
        quote do
          Enum.any?(unquote(requirements), fn
            {resource, action} ->
              Rail.Users.can?(var!(unquote(scope_arg)), resource, action)

            action when is_atom(action) ->
              Rail.Users.can?(var!(unquote(scope_arg)), action)
          end)
        end

      :error ->
        cond do
          Keyword.has_key?(opts, :resource) ->
            resource = Keyword.fetch!(opts, :resource)
            action = Keyword.fetch!(opts, :action)

            quote do
              Rail.Users.can?(var!(unquote(scope_arg)), unquote(resource), unquote(action))
            end

          Keyword.has_key?(opts, :action) ->
            action = Keyword.fetch!(opts, :action)

            quote do
              Rail.Users.can?(var!(unquote(scope_arg)), unquote(action))
            end
        end
    end
  end
end
