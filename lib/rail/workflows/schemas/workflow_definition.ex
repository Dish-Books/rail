defmodule Rail.Workflows.Schemas.WorkflowDefinition do
  @moduledoc """
  What a `.rail/workflows/` file says, as last read from the project's default branch. There is no table
  behind this: it is kept on its `Rail.Workflows.Schemas.Workflow` row.
  """
  use Rail.Schema

  alias Oban.Cron.Expression

  @keys ["name", "schedule", "instructions"]
  @weekdays ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]

  @primary_key false
  embedded_schema do
    field :name, :string
    field :instructions, :string
    # Cron, in UTC.
    field :schedule, :string
  end

  @doc """
  Builds a definition from a file's keys, refusing one short of a name, instructions or a schedule Rail can step.
  """
  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [:name, :instructions, :schedule])
    |> update_change(:name, &String.trim/1)
    |> update_change(:instructions, &String.trim/1)
    |> update_change(:schedule, &String.trim/1)
    |> validate_required([:name, :instructions, :schedule])
    |> validate_change(:schedule, fn :schedule, schedule ->
      # `@reboot` parses, but has no next time to start at.
      case Expression.parse(schedule) do
        {:ok, %Expression{reboot?: false}} -> []
        {:ok, %Expression{reboot?: true}} -> [schedule: "is not a time"]
        {:error, error} -> [schedule: "is not a cron expression: #{Exception.message(error)}"]
      end
    end)
  end

  @doc """
  Reads a workflow file's text into `{:ok, definition}`, or `{:error, message}` naming what is wrong with it.
  """
  def parse(text) when is_binary(text) do
    with true <- String.valid?(text) || {:error, "not UTF-8 text"},
         {:ok, %{} = keys} <- read_yaml(text),
         [] <- Map.keys(keys) -- @keys do
      %__MODULE__{}
      |> changeset(keys)
      |> apply_action(:parse)
      |> case do
        {:ok, definition} -> {:ok, definition}
        {:error, changeset} -> {:error, describe(changeset)}
      end
    else
      {:error, message} -> {:error, message}
      {:ok, _not_a_map} -> {:error, "not a map of name, schedule and instructions"}
      unknown -> {:error, "keys Rail does not know: #{Enum.map_join(unknown, ", ", &inspect/1)}"}
    end
  end

  @doc """
  The schedule in words when it starts once a day, every day or on one weekday, and otherwise its expression.
  """
  def schedule_label(%__MODULE__{schedule: schedule}) do
    cron = Expression.parse!(schedule)
    every = &(MapSet.size(&1) == Enum.count(&2))

    with [minute] <- MapSet.to_list(cron.minutes),
         [hour] <- MapSet.to_list(cron.hours),
         true <- every.(cron.days, 1..31) and every.(cron.months, 1..12) do
      at = "at #{pad(hour)}:#{pad(minute)}"

      case MapSet.to_list(cron.weekdays) do
        [weekday] -> "#{Enum.at(@weekdays, weekday)} #{at}"
        weekdays when length(weekdays) == 7 -> "Every day #{at}"
        _some_weekdays -> schedule
      end
    else
      _not_daily -> schedule
    end
  end

  defp read_yaml(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, keys} -> {:ok, keys}
      {:error, error} -> {:error, "not YAML: #{Exception.message(error)}"}
    end
  end

  defp describe(changeset) do
    changeset
    |> traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
