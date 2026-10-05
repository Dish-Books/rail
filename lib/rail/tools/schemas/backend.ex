defmodule Rail.Tools.Schemas.Backend do
  @moduledoc """
  Schema for a CLI backend: where its executable lives, which models may be
  selected for it, and what the last usage probe found out about the account
  signed in to it.
  """
  use Rail.Schema

  @names [:claude]
  @statuses [:not_configured, :signed_out, :unavailable, :ready]

  @primary_key {:id, UXID, autogenerate: true, prefix: "bkd"}
  schema "backends" do
    field :name, Ecto.Enum, values: @names
    # Tells apart two backends of the same kind, e.g. a work and a personal account.
    field :label, :string
    field :executable_path, :string, default: ""
    # A model the user has made available on this backend.
    embeds_many :models, Model, primary_key: false, on_replace: :delete do
      @derive Jason.Encoder
      field :id, :string
      field :display_name, :string
    end

    field :status, Ecto.Enum, values: @statuses, default: :not_configured
    field :account_label, :string
    field :account_detail, :string
    field :fetched_at, :utc_datetime_usec
    field :unavailable_reason, :string
    # When the backend stopped being signed in with nobody having signed it out:
    # Claude refused its sign-in, or a probe found a ready one signed out. Cleared
    # once a probe finds it signed in again, or it is signed out on purpose.
    field :session_lost_at, :utc_datetime_usec

    # A group of quota limits the CLI reported, with the windows it measured
    # them over carried in `details`.
    embeds_many :usage, Usage, primary_key: false, on_replace: :delete do
      @derive Jason.Encoder
      field :name, :string
      field :count, :integer, default: 0
      field :details, :map, default: %{}
    end

    timestamps()
  end

  @config_fields [:name, :label, :executable_path]
  @required_config_fields [:name, :executable_path]
  @usage_fields [
    :name,
    :status,
    :account_label,
    :account_detail,
    :fetched_at,
    :unavailable_reason,
    :session_lost_at
  ]

  @doc "Returns the backends that can be configured."
  def names, do: @names

  @doc "Returns the statuses a usage probe can report."
  def statuses, do: @statuses

  @doc """
  Returns the environment variable a backend's CLI reads its config directory
  from.
  """
  def env_var(:claude), do: "CLAUDE_CONFIG_DIR"

  @doc """
  Returns the directory a backend's CLI keeps its signed-in account in. It is
  Rail's, one per backend, so no two backends can share an account by accident
  and none touches the account the CLI uses outside Rail.
  """
  def config_dir(%__MODULE__{id: id}) when is_binary(id) do
    root = Application.get_env(:rail, :backends_root) || Path.join(System.user_home!(), ".rail/backends")
    Path.join(root, id)
  end

  @doc "What a CLI is called wherever Rail names it."
  def cli_name(:claude), do: "Claude Code"

  @doc """
  What an account is called wherever Rail names it: its CLI, then what the user
  called it or, failing that, who is signed in to it.
  """
  def display_name(%__MODULE__{name: name} = backend) do
    case short_name(backend) do
      account when is_binary(account) -> "#{cli_name(name)} · #{account}"
      nil -> cli_name(name)
    end
  end

  @doc "What tells an account apart from the others on its CLI, or nil when nothing does."
  def short_name(%__MODULE__{} = backend) do
    Enum.find([backend.label, backend.account_label], &(&1 not in [nil, ""]))
  end

  @doc "Why a run or a pass could not start: no signed-in account offers its role's model."
  def no_account_error(model, role_name) do
    "No signed-in account offers #{model}. Sign one in on Settings › Backends, or pick another model for #{role_name}."
  end

  @doc """
  How much room `backend` has for a new conversation on `model`, read from the
  usage its last probe stored.

  Each of the 5-hour, weekly and model's weekly windows is measured as its
  percent left over the fraction of its length still to run, so a window about
  to reset stands higher than one that must last for days. The account stands
  at its tightest window, and at 0 while any window is used up. Returns its
  `standing`, its `tightest` window, the windows `used_up` and when the last of
  those `resets_at`. A window whose reset has passed counts as fresh.
  """
  def calculate_standing(%__MODULE__{usage: usage}, model, now \\ DateTime.utc_now()) do
    windows =
      for %{details: details} <- usage || [],
          window <- windows(details),
          measured = measure_window(window, model, now),
          is_map(measured),
          do: measured

    used_up = Enum.filter(windows, &(&1.remaining_percent <= 0))
    tightest = Enum.min_by(windows, & &1.measure, fn -> nil end)

    standing =
      cond do
        used_up != [] -> 0.0
        tightest -> tightest.measure
        true -> 100.0
      end

    resets_at =
      used_up |> Enum.map(& &1.resets_at) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)

    %{standing: standing, tightest: tightest, used_up: used_up, resets_at: resets_at}
  end

  @doc """
  Builds a changeset for the configuration the user owns: the label, the
  executable path and the models selectable on it.
  """
  def changeset(backend, attrs) do
    backend
    |> cast(attrs, @config_fields)
    |> update_change(:executable_path, &String.trim(&1 || ""))
    |> update_change(:label, &String.trim/1)
    |> validate_required(@required_config_fields)
    |> cast_embed(:models, with: &model_changeset/2)
  end

  @doc """
  Builds a changeset for what a usage probe reports. It never touches the
  executable path or the models, so a refresh cannot clobber the user's config.
  """
  def usage_changeset(backend, attrs) do
    backend
    |> cast(attrs, @usage_fields)
    |> validate_required([:name, :status])
    |> cast_embed(:usage, with: &usage_group_changeset/2)
  end

  defp windows(%{"windows" => windows}) when is_list(windows), do: windows
  defp windows(%{"remaining_percent" => percent} = window) when is_number(percent), do: [window]
  defp windows(_unmeasured), do: []

  # A window's label is what the probe called it; anything but the three windows
  # a run can spend is left out, as is one the CLI could not measure.
  defp measure_window(%{"label" => label, "remaining_percent" => percent} = window, model, now)
       when is_binary(label) and is_number(percent) do
    with {kind, display, hours} <- window_kind(label, model) do
      resets_at = parse_reset(window["resets_at"])
      left = if resets_at, do: DateTime.diff(resets_at, now, :second) / 3600 / hours, else: 1.0

      if left <= 0 do
        %{kind: kind, label: display, remaining_percent: 100.0, resets_at: nil, measure: 100.0}
      else
        percent = percent |> max(0) |> min(100) |> Kernel./(1)
        %{kind: kind, label: display, remaining_percent: percent, resets_at: resets_at, measure: percent / min(left, 1.0)}
      end
    end
  end

  defp measure_window(_window, _model, _now), do: nil

  defp window_kind(label, _model) when label in ["Session", "5-Hour"], do: {:five_hour, "5-hour", 5}
  defp window_kind("Weekly", _model), do: {:weekly, "Weekly", 168}

  defp window_kind("Weekly · " <> model_name = label, model) when is_binary(model) do
    slug = model_name |> String.downcase() |> String.replace([" ", "."], "-")
    if String.contains?(String.downcase(model), slug), do: {:model_weekly, label, 168}
  end

  defp window_kind(_label, _model), do: nil

  defp parse_reset(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp parse_reset(at) when is_integer(at) do
    unit = if at > 10_000_000_000, do: :millisecond, else: :second
    DateTime.from_unix!(at, unit)
  end

  defp parse_reset(_unknown), do: nil

  # A model with no display name shows as its id rather than as nothing.
  defp model_changeset(model, attrs) do
    model
    |> cast(attrs, [:id, :display_name])
    |> update_change(:id, &String.trim/1)
    |> update_change(:display_name, &String.trim/1)
    |> validate_required([:id])
    |> default_display_name()
  end

  defp default_display_name(changeset) do
    case get_field(changeset, :display_name) do
      name when is_binary(name) and name != "" -> changeset
      _blank -> put_change(changeset, :display_name, get_field(changeset, :id))
    end
  end

  defp usage_group_changeset(usage, attrs) do
    usage
    |> cast(attrs, [:name, :count, :details])
    |> validate_required([:name])
    |> validate_number(:count, greater_than_or_equal_to: 0)
  end
end
