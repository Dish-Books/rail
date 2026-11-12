defmodule RailWeb.AuthHTML do
  @moduledoc false
  use RailWeb, :html

  def denied(assigns) do
    ~H"""
    <div
      class="min-h-dvh flex items-center justify-center bg-white dark:bg-slate-900 p-6"
      id="auth-denied"
    >
      <div class="max-w-md w-full space-y-4 text-center">
        <h1
          class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
          id="auth-denied-title"
        >
          Can't sign you in
        </h1>

        <p
          :if={Phoenix.Flash.get(@flash, :error)}
          class="rounded-md bg-red-50 dark:bg-red-400/10 p-4 border border-red-200 dark:border-red-400/30 text-sm text-red-700 dark:text-red-300"
          id="auth-denied-message"
        >
          {Phoenix.Flash.get(@flash, :error)}
        </p>

        <p :if={!@access?} class="text-sm text-slate-500 dark:text-slate-400" id="auth-denied-help">
          Rail is invite only. An admin invites the email address on your GitHub account, then you sign in.
        </p>

        <p :if={@access?} class="text-sm text-slate-500 dark:text-slate-400" id="auth-denied-help">
          Rail is invite only. Ask an admin to invite this address, or sign out of Cloudflare Access and use the address you were invited with.
        </p>

        <.button :if={!@access?} href={~p"/auth/github"} variant="primary" id="auth-denied-retry">
          Try again
        </.button>

        <div :if={@access?} class="flex items-center justify-center gap-3">
          <.button href="/cdn-cgi/access/logout" variant="primary" id="auth-denied-other-address">
            Use another address
          </.button>
          <.button href={~p"/auth/github"} variant="secondary" id="auth-denied-github">
            <.icon name="pi-github-logo" class="size-4" /> Sign in with GitHub
          </.button>
        </div>
      </div>
    </div>
    """
  end
end
