defmodule Rail.Mcp.Utils.RunToolCarryScreen do
  @moduledoc """
  Carries a screen state an earlier round shot into this round as it is, for a state QA judged the round's change
  left alone. A state it neither shoots nor carries drops off the human's screens once the round has any.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Carries the state `arguments["key"]` on `task` forward, and says which commit its picture is still of.
  """
  def run_tool_carry_screen(%Task{} = task, %{"key" => key}, _opts) when is_binary(key) do
    case Pipeline.carry_screen(task, key) do
      {:ok, %{commit: commit, file: file}} ->
        {:ok,
         "Carried #{key} into this round as it is: #{file}, the picture on #{String.slice(commit || "no commit", 0, 7)}."}

      {:error, :current} ->
        {:refused, "Refused, nothing changed. #{key} is already this round's, shot or carried."}

      {:error, :not_found} ->
        {:refused,
         "Refused, nothing carried. No earlier round has a state `#{key}`. Shoot it with `save_screen` instead."}
    end
  end

  def run_tool_carry_screen(%Task{}, _arguments, _opts) do
    {:refused, "Refused, nothing carried. carry_screen needs the `key` of a state an earlier round shot."}
  end
end
