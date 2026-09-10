defmodule RailWeb.ErrorJSON do
  @moduledoc false

  def render("unprocessable_entity.json", %{changeset: %Ecto.Changeset{} = changeset}) do
    %{errors: changeset_errors(changeset)}
  end

  def render(template, _assigns) do
    %{errors: [%{detail: Phoenix.Controller.status_message_from_template(template)}]}
  end

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&expand_message/1)
    |> flatten_errors()
  end

  defp expand_message({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _whole, key ->
      Enum.find_value(opts, key, fn {opt_key, value} ->
        if Atom.to_string(opt_key) == key, do: to_string(value)
      end)
    end)
  end

  defp flatten_errors(errors, source_prefix \\ nil) do
    Enum.flat_map(errors, fn {field, value} ->
      flatten_field(value, join_source(source_prefix, field))
    end)
  end

  defp flatten_field([message | _rest] = messages, source) when is_binary(message) do
    Enum.map(messages, fn detail -> %{detail: detail, source: source} end)
  end

  defp flatten_field(entries, source) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> flatten_errors(nested, "#{source}.#{index}") end)
  end

  defp flatten_field(nested, source) when is_map(nested) do
    flatten_errors(nested, source)
  end

  defp join_source(nil, field), do: to_string(field)
  defp join_source(source_prefix, field), do: "#{source_prefix}.#{field}"
end
