defmodule Rail.Domain.Formatters do
  @moduledoc """
  Formatting utilities for task statuses, summaries, tokens, costs, and durations.
  """

  alias Rail.Domain.Enums.TaskStage

  @doc """
  Derives an issue title from typed idea ask text.
  Extracts the first non-blank line, trimmed.
  If <= 90 characters, returns it as-is.
  If > 90 characters, cuts at the last whitespace boundary before or at character 90
  and appends an ellipsis `…`. If no whitespace boundary exists, cuts at 90 and appends `…`.
  Empty input returns `""`.
  """
  def summarize_ask(nil), do: ""
  def summarize_ask(""), do: ""

  def summarize_ask(ask) when is_binary(ask) do
    lines = String.split(ask, ~r/\r?\n/)

    case Enum.find_value(lines, fn line ->
           trimmed = String.trim(line)
           if trimmed == "", do: nil, else: trimmed
         end) do
      trimmed when is_binary(trimmed) ->
        truncate_ask(trimmed)

      nil ->
        ""
    end
  end

  @doc """
  Pulls error from `task.error` or current run error if stage is failed.
  Takes first non-blank line, trims and collapses whitespace runs `\\s+` to single space.
  If > 140 chars, truncate to 140 chars + `...`.
  """
  def overview_detail_for(task, runs \\ %{})

  def overview_detail_for(nil, _runs), do: nil

  def overview_detail_for(task, runs) do
    case raw_error_text(task, runs) do
      raw_text when is_binary(raw_text) ->
        collapse_error_lines(raw_text)

      nil ->
        nil
    end
  end

  @doc """
  Formats a task's stage label per spec 04 §1.9 with full precedence:
  1. Active chat: `"Chatting with {RoleName}"`
  2. Rebasing: `"Queued to rebase"` / `"Retrying the rebase shortly"` / `"Rebasing the branch"` / `"Rebase needs an answer"` / `"Rebase failed"`
  3. Cycle suffix: `" · rework X of Y"` when reworked and not before engineer
  4. State label: queued (conflicts / retry / queued), running, blocked, failed, awaiting approval (by stage or conflicts)
  """
  def stage_label(task, opts \\ [])

  def stage_label(nil, _opts), do: "Waiting on you"

  def stage_label(task, opts) do
    chat_role_id = get_field(task, :active_chat_role_id)

    cond do
      chat_role_id != nil ->
        role_name = role_name_for_chat(chat_role_id, opts)
        "Chatting with #{role_name}"

      rebasing?(task) and stage_state(task) != :awaiting_approval ->
        rebase_label(task, opts)

      true ->
        standard_stage_label(task, opts)
    end
  end

  @doc """
  Formats an integer token count into a compact string:
  - >= 1_000_000: "X.XXM" (e.g. 1_230_000 -> "1.23M", 2_500_000 -> "2.5M")
  - >= 1_000: "X.XK" (e.g. 1_500 -> "1.5K", 2_000 -> "2K")
  - < 1_000: "X" (e.g. 500 -> "500")
  If `suffix: true` is passed, appends " tokens" (or " token" for 1).
  """
  def format_tokens(count, opts \\ [])

  def format_tokens(nil, opts) do
    if Keyword.get(opts, :suffix, false) do
      "0 tokens"
    else
      "0"
    end
  end

  def format_tokens(n, opts) when is_float(n) do
    format_tokens(round(n), opts)
  end

  def format_tokens(n, opts) when is_integer(n) do
    compact = compact_tokens(n)

    if Keyword.get(opts, :suffix, false) do
      unit = if n == 1, do: "token", else: "tokens"
      "#{compact} #{unit}"
    else
      compact
    end
  end

  @doc """
  Formats a numeric or Decimal cost into currency format.
  USD: "$0.0250", "$1.5000", "$0.0000"
  Other: "12.3456 EUR"
  """
  def format_cost(cost, currency_or_opts \\ "USD")

  def format_cost(nil, _currency_or_opts), do: ""

  def format_cost(cost, currency) when is_binary(currency) do
    dec = to_decimal(cost)
    rounded = Decimal.round(dec, 4)

    if currency == "USD" do
      "$#{rounded}"
    else
      "#{rounded} #{currency}"
    end
  end

  def format_cost(cost, opts) when is_list(opts) do
    currency = Keyword.get(opts, :currency, "USD")
    format_cost(cost, currency)
  end

  @doc """
  Formats seconds into duration:
  >= 3600s: "Xh Ym Zs"
  >= 60s: "Xm Ys"
  < 60s: "Xs"
  """
  def format_duration(nil), do: ""

  def format_duration(seconds) when is_float(seconds) do
    format_duration(round(seconds))
  end

  def format_duration(seconds) when is_integer(seconds) do
    total_seconds = max(seconds, 0)
    h = div(total_seconds, 3600)
    remainder = rem(total_seconds, 3600)
    m = div(remainder, 60)
    s = rem(remainder, 60)

    cond do
      h > 0 -> "#{h}h #{m}m #{s}s"
      m > 0 -> "#{m}m #{s}s"
      true -> "#{s}s"
    end
  end

  # Private Helpers

  defp truncate_ask(trimmed) do
    if String.length(trimmed) <= 90 do
      trimmed
    else
      sub = String.slice(trimmed, 0, 90)
      char_at_90 = String.at(trimmed, 90)
      at_boundary = is_binary(char_at_90) and Regex.match?(~r/^\s$/, char_at_90)

      boundary =
        if at_boundary do
          90
        else
          find_last_whitespace_index(sub)
        end

      if is_integer(boundary) and boundary > 0 do
        trimmed
        |> String.slice(0, boundary)
        |> String.trim_trailing()
        |> Kernel.<>("…")
      else
        sub <> "…"
      end
    end
  end

  defp raw_error_text(task, runs) do
    err = get_field(task, :error)

    cond do
      has_text?(err) ->
        err

      stage_state(task) == :failed ->
        failed_run_error(task, runs)

      true ->
        nil
    end
  end

  defp failed_run_error(task, runs) do
    role_id = get_field(task, :current_role_id)

    task_runs =
      if is_map(runs) and map_size(runs) > 0 do
        runs
      else
        get_field(task, :runs) || %{}
      end

    run = if role_id, do: get_run(task_runs, role_id)
    run_error = if run, do: get_field(run, :error)

    if has_text?(run_error), do: run_error
  end

  defp collapse_error_lines(raw_text) do
    first_non_empty =
      raw_text
      |> String.split(~r/\r?\n/)
      |> Enum.find_value(fn line ->
        trimmed = String.trim(line)
        if trimmed != "", do: String.replace(trimmed, ~r/\s+/, " ")
      end)

    truncate_error_line(first_non_empty)
  end

  defp truncate_error_line(collapsed) do
    if String.length(collapsed) > 140 do
      String.slice(collapsed, 0, 140) <> "..."
    else
      collapsed
    end
  end

  defp rebase_label(task, opts) do
    case stage_state(task) do
      :queued ->
        if waiting_to_retry?(task, opts),
          do: "Retrying the rebase shortly",
          else: "Queued to rebase"

      :running ->
        "Rebasing the branch"

      s when s in [:blocked, :paused_question, :blocked_rework] ->
        "Rebase needs an answer"

      :failed ->
        "Rebase failed"

      _other ->
        "Queued to rebase"
    end
  end

  defp standard_stage_label(task, opts) do
    current_stage = stage(task)
    cycle = rework_cycle_suffix(task, current_stage, opts)
    stage_name = stage_label_name(current_stage)

    case stage_state(task) do
      :queued ->
        queued_label(task, stage_name, cycle, opts)

      :running ->
        "#{stage_name} running#{cycle}"

      s when s in [:blocked, :paused_question, :blocked_rework] ->
        "#{stage_name} needs an answer"

      :failed ->
        "#{stage_name} failed"

      :awaiting_approval ->
        awaiting_approval_label(task, current_stage, opts)

      _other ->
        "Waiting on you"
    end
  end

  defp queued_label(task, stage_name, cycle, opts) do
    cond do
      conflicted?(task) ->
        "Conflicts - needs a rebase"

      waiting_to_retry?(task, opts) ->
        "Retrying #{stage_name} shortly#{cycle}"

      true ->
        "Queued for #{stage_name}#{cycle}"
    end
  end

  defp awaiting_approval_label(task, current_stage, opts) do
    if conflicted?(task) do
      "Conflicts - needs a rebase"
    else
      stage_approval_label(task, current_stage, opts)
    end
  end

  defp stage_approval_label(_task, :product, _opts), do: "Review the ticket"

  defp stage_approval_label(task, :design, opts) do
    if design_picked?(task, opts), do: "Review the design", else: "Pick a design direction"
  end

  defp stage_approval_label(_task, :architect, _opts), do: "Review the plan"
  defp stage_approval_label(_task, :engineer, _opts), do: "Ready to send to review"
  defp stage_approval_label(_task, :review, _opts), do: "Review needs your call"
  defp stage_approval_label(_task, stage, _opts) when stage in [:qa, :qa_lead], do: "QA needs your call"
  defp stage_approval_label(_task, :demo, _opts), do: "Review the demo"
  defp stage_approval_label(_task, :ready_to_merge, _opts), do: "Ready to merge"
  defp stage_approval_label(_task, _other, _opts), do: "Waiting on you"

  defp rework_cycle_suffix(task, current_stage, opts) do
    rework_cycles = get_field(task, :rework_cycles) || 0
    has_been_reworked = rework_cycles > 0
    is_before_engineer = TaskStage.before?(current_stage, :engineer)

    if has_been_reworked and not is_before_engineer do
      ceiling = get_field(task, :rework_ceiling) || Keyword.get(opts, :rework_ceiling, 5)
      " · rework #{rework_cycles} of #{ceiling}"
    else
      ""
    end
  end

  defp find_last_whitespace_index(string) do
    case Regex.scan(~r/\s/, string, return: :index) do
      [] ->
        nil

      matches ->
        [{idx, _len}] = List.last(matches)
        idx
    end
  end

  defp has_text?(str) when is_binary(str), do: String.trim(str) != ""
  defp has_text?(_other), do: false

  defp get_run(task_runs, role_id) when is_map(task_runs) do
    Map.get(task_runs, role_id) || Map.get(task_runs, to_string(role_id))
  end

  defp get_run(_runs, _role_id), do: nil

  defp rebasing?(task), do: get_field(task, :is_rebasing) == true

  defp waiting_to_retry?(task, opts) do
    case get_field(task, :is_waiting_to_retry) do
      bool when is_boolean(bool) ->
        bool

      nil ->
        case get_field(task, :retry_after) do
          %DateTime{} = retry_after ->
            now = Keyword.get(opts, :now) || DateTime.utc_now()
            DateTime.after?(retry_after, now)

          _other ->
            false
        end
    end
  end

  defp conflicted?(task) do
    cond do
      get_field(task, :shows_as_conflicted) == true ->
        true

      get_field(task, :conflicted) == true ->
        true

      get_field(task, :has_merge_conflicts) == true and not rebasing?(task) ->
        stage_state(task) in [:queued, :awaiting_approval, nil]

      get_field(task, :mergeability) in [:conflicts, "conflicts"] and not rebasing?(task) ->
        stage_state(task) in [:queued, :awaiting_approval, nil]

      true ->
        false
    end
  end

  defp design_picked?(task, opts) do
    cond do
      Keyword.get(opts, :design_picked, false) == true ->
        true

      get_field(task, :has_picked_design) == true ->
        true

      get_field(task, :design_picked_key) != nil ->
        true

      get_field(task, :picked_design_key) != nil ->
        true

      true ->
        case get_field(task, :design) do
          %{picked_key: pk} when pk != nil -> true
          _other -> false
        end
    end
  end

  defp role_name_for_chat(role_id, opts) do
    role_id_str = to_string(role_id)

    cond do
      Keyword.has_key?(opts, :role_name) ->
        Keyword.get(opts, :role_name)

      Keyword.has_key?(opts, :roles) ->
        roles = Keyword.get(opts, :roles, [])
        match = Enum.find(roles, fn r -> get_field(r, :id) == role_id or get_field(r, :id) == role_id_str end)

        if match do
          get_field(match, :name) || default_role_name(role_id_str)
        else
          default_role_name(role_id_str)
        end

      true ->
        default_role_name(role_id_str)
    end
  end

  defp default_role_name("product"), do: "Product"
  defp default_role_name("design"), do: "Designer"
  defp default_role_name("designer"), do: "Designer"
  defp default_role_name("architect"), do: "Architect"
  defp default_role_name("engineer"), do: "Engineer"
  defp default_role_name("review"), do: "Reviewer"
  defp default_role_name("reviewer"), do: "Reviewer"
  defp default_role_name("qa"), do: "QA"
  defp default_role_name("qa_lead"), do: "QA Lead"
  defp default_role_name("demo"), do: "Demo"

  defp default_role_name(other) when is_binary(other) do
    to_title(other)
  end

  defp stage_label_name(stage) do
    TaskStage.label(stage) || to_title(stage)
  end

  defp to_title(nil), do: ""

  defp to_title(atom) when is_atom(atom) do
    atom |> to_string() |> to_title()
  end

  defp to_title(string) when is_binary(string) do
    string
    |> String.split("_", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp stage(task), do: task |> get_field(:stage) |> to_atom()
  defp stage_state(task), do: task |> get_field(:stage_state) |> to_atom()

  defp to_atom(nil), do: nil
  defp to_atom(atom) when is_atom(atom), do: atom

  defp to_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    _error -> nil
  end

  defp to_atom(_other), do: nil

  defp get_field(%_struct_mod{} = struct, field), do: Map.get(struct, field)

  defp get_field(map, field) when is_map(map) do
    case Map.fetch(map, field) do
      {:ok, val} ->
        val

      :error ->
        case Map.fetch(map, to_string(field)) do
          {:ok, val} -> val
          :error -> nil
        end
    end
  end

  defp get_field(_other, _field), do: nil

  defp compact_tokens(n) when n >= 1_000_000 do
    rounded = Float.round(n / 1_000_000, 2)
    formatted = format_rounded_float(rounded)
    "#{formatted}M"
  end

  defp compact_tokens(n) when n >= 1_000 do
    rounded = Float.round(n / 1_000, 1)
    formatted = format_rounded_float(rounded)
    "#{formatted}K"
  end

  defp compact_tokens(n), do: "#{n}"

  defp format_rounded_float(f) do
    if f == trunc(f) do
      "#{trunc(f)}"
    else
      :erlang.float_to_binary(f, [:compact, decimals: 2])
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n) or is_float(n), do: Decimal.new("#{n}")
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
end
