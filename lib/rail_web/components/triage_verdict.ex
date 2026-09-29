defmodule RailWeb.Components.TriageVerdict do
  @moduledoc """
  The badges a triage item is read by: its kind, bug or feature request, and
  the verdict the pass reached on it.
  """
  use RailWeb, :html

  alias Rail.Triage.Schemas.Item

  attr :kind, :atom, required: true
  attr :verdict, :atom, default: nil, doc: "draws the verdict pill instead of the kind badge"
  attr :id, :string, default: nil

  def triage_verdict(%{verdict: nil} = assigns) do
    assigns = assign(assigns, :style, kind_style(assigns.kind))

    ~H"""
    <span
      id={@id}
      data-qa="triage-kind"
      class={[
        "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[11px] font-bold uppercase tracking-wider shrink-0",
        @style.class
      ]}
    >
      <.icon name={@style.icon} class="size-3" />{Item.kind_label(@kind)}
    </span>
    """
  end

  def triage_verdict(assigns) do
    assigns = assign(assigns, :style, verdict_style(assigns.verdict))

    ~H"""
    <span
      id={@id}
      data-qa="triage-verdict"
      class={[
        "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[11px] font-bold whitespace-nowrap shrink-0 border",
        @style.class
      ]}
    >
      <.icon name={@style.icon} class="size-3" />{Item.verdict_label(@verdict)}
    </span>
    """
  end

  @doc """
  The colors and icon an item of `kind` is drawn in, shared with the marks and chips that point at it.
  """
  def kind_style(:bug), do: %{class: "bg-red-100 dark:bg-red-950 text-red-700 dark:text-red-300", icon: "pi-bug"}

  def kind_style(:feature_request),
    do: %{class: "bg-violet-100 dark:bg-violet-950 text-violet-700 dark:text-violet-300", icon: "pi-lightbulb"}

  defp verdict_style(:confirmed),
    do: %{
      class: "border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-800 dark:text-red-200",
      icon: "pi-check-circle-fill"
    }

  defp verdict_style(:partly_built),
    do: %{
      class: "border-amber-300 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200",
      icon: "pi-circle-half-fill"
    }

  defp verdict_style(verdict) when verdict in [:already_fixed, :built],
    do: %{
      class:
        "border-emerald-300 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-950/40 text-emerald-800 dark:text-emerald-200",
      icon: "pi-seal-check-fill"
    }

  defp verdict_style(verdict) when verdict in [:not_reproduced, :not_built],
    do: %{
      class: "border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800/40 text-slate-700 dark:text-slate-300",
      icon: "pi-circle"
    }
end
